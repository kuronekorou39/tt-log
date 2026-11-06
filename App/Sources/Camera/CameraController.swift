import Combine
import Foundation
import TTLogCore
import UIKit

private let wholeSessionKey = "camera.recordWholeSession"

/// カメラ端末の中心。スコアボードの状態を見て、録画を始め・止める。
///
/// ゲームごと（既定）：
/// - ゲーム中（playing）になったら録画を始める
/// - ゲームが終わったら `postRollSeconds` 秒おいて止める（最後のラリーの余韻まで残す）
/// - 止める前にゲームが再開したら（最後の点の取り消しなど）、そのまま続ける
/// 記録中ずっと：
/// - スコアボードで記録を始めてから終えるまで、ゲームの間も止めずに1本で撮る
/// 手動録画中は自動では止めない。
///
/// 端末の状態（温度・電池・空き容量）は10秒ごとに `DeviceLog` に残す。
@MainActor
final class CameraController: ObservableObject {
    let client = PeerClient()
    let recorder = CameraRecorder()
    let library = CameraLibrary()
    let deviceLog = DeviceLog()

    @Published var autoRecord = true
    /// 記録中はゲームの間も止めずに撮る（端末内に保存する）。
    @Published var recordWholeSession = UserDefaults.standard.bool(forKey: wholeSessionKey) {
        didSet {
            UserDefaults.standard.set(recordWholeSession, forKey: wholeSessionKey)
            handle(client.snapshot)
        }
    }
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var recordingLabel = ""
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var freeBytes: Int64?
    @Published private(set) var message: String?

    private struct Target: Equatable {
        var sessionId: String
        var gameIndex: Int?
    }

    /// いま録画している（または開始を頼んだ）もの。
    private var recording: Target?
    private var recordingFile: String?
    private var recordingWhole = false
    private var manual = false
    /// 止めたあとに始め直すもの（ゲームが切り替わったとき）。
    private var restartAfterStop: Target?
    private var pendingStop: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var statusTimer: Timer?

    static let postRollSeconds = 3
    /// 空きがこれより少なければ録画を始めない。
    static let minimumFreeBytes: Int64 = 1_000_000_000
    /// 空きがこれより少なければ注意を出す。
    static let lowFreeBytes: Int64 = 5_000_000_000

    init() {
        recorder.onStarted = { [weak self] url, at in self?.clipStarted(url, at: at) }
        recorder.onFinished = { [weak self] url, error in self?.clipFinished(url, error: error) }
        client.$snapshot
            .sink { [weak self] s in self?.handle(s) }
            .store(in: &cancellables)
        UIDevice.current.isBatteryMonitoringEnabled = true
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalChanged() }
        })
        statusTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDeviceStatus() }
        }
        updateDeviceStatus()
        library.reload()
    }

    func start(manualHost: String?) async {
        client.start(manualHost: manualHost)
        await recorder.startSession()
    }

    /// 手動で録画を始める／止める。
    func toggleManualRecording() {
        if recording != nil {
            pendingStop?.cancel()
            restartAfterStop = nil
            if !manual, autoRecord {
                // 自動録画を手で止めたら、すぐ始め直さないよう自動を切る
                autoRecord = false
                message = "自動録画を OFF にしました"
            }
            recorder.stopRecording()
            return
        }
        let s = client.snapshot
        let target: Target
        if let s, let id = s.sessionId {
            target = Target(sessionId: id, gameIndex: s.phase == .playing ? s.gameIndex : nil)
        } else {
            target = Target(sessionId: "manual-\(Int(Date().timeIntervalSince1970))", gameIndex: nil)
        }
        manual = true
        startClip(target)
    }

    // MARK: - スコアボードの状態

    private func handle(_ s: ScoreboardSnapshot?) {
        guard let s else { return }
        if let id = s.sessionId { updateMarks(s, sessionId: id) }
        guard autoRecord, !manual else { return }

        // 記録を終えた（idle）ときも、ゲームが終わったときと同じく止める
        if let target = autoTarget(s) {
            pendingStop?.cancel()
            pendingStop = nil
            if recording == nil {
                startClip(target)
            } else if recording != target {
                // 別のゲームになった：いまの録画を止めてから始め直す
                restartAfterStop = target
                recorder.stopRecording()
            }
        } else if recording != nil, pendingStop == nil {
            pendingStop = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.postRollSeconds))
                guard !Task.isCancelled else { return }
                self?.pendingStop = nil
                self?.recorder.stopRecording()
            }
        }
    }

    /// いまの状態で自動録画すべきもの。録画しない状態なら nil。
    private func autoTarget(_ s: ScoreboardSnapshot) -> Target? {
        guard let id = s.sessionId else { return nil }
        if recordWholeSession { return Target(sessionId: id, gameIndex: nil) }
        return s.shouldRecord ? Target(sessionId: id, gameIndex: s.gameIndex) : nil
    }

    /// 各ゲームの得点の時刻を、この端末の時計に直して残す。
    private func updateMarks(_ s: ScoreboardSnapshot, sessionId: String) {
        let startedAt = s.sessionStartedAt.map { client.localDate(fromRemote: $0) } ?? Date()
        var index = library.ensure(id: sessionId, playerNames: s.playerNames, startedAt: startedAt)
        let marks = s.points.map {
            CameraSessionIndex.Mark(winner: $0.winner, at: client.localDate(fromRemote: $0.at), scores: $0.scores)
        }
        let game = CameraSessionIndex.Game(gameIndex: s.gameIndex, points: marks, finished: s.phase != .playing)
        if let i = index.games.firstIndex(where: { $0.gameIndex == s.gameIndex }) {
            guard index.games[i] != game else { return }
            index.games[i] = game
        } else {
            index.games.append(game)
        }
        index.playerNames = s.playerNames
        index.clockOffsetMs = client.clockOffsetMs
        library.save(index)
    }

    // MARK: - 録画

    private func startClip(_ target: Target) {
        if let free = freeBytes, free < Self.minimumFreeBytes {
            message = "空き容量が足りないため録画を始めません"
            manual = false
            return
        }
        if thermalState == .critical {
            message = "端末が熱くなりすぎているため録画を始めません"
            manual = false
            return
        }
        let names = client.snapshot?.playerNames ?? []
        let startedAt = client.snapshot?.sessionStartedAt.map { client.localDate(fromRemote: $0) } ?? Date()
        let index = library.ensure(id: target.sessionId, playerNames: names, startedAt: startedAt)
        let file: String
        let whole = !manual && target.gameIndex == nil
        if let g = target.gameIndex {
            let part = index.clips.filter { $0.gameIndex == g }.count + 1
            file = String(format: "game%02d-%d.mov", g + 1, part)
        } else if whole {
            let part = index.clips.filter { $0.wholeSession == true }.count + 1
            file = String(format: "whole-%02d.mov", part)
        } else {
            file = "manual-\(Int(Date().timeIntervalSince1970)).mov"
        }
        recording = target
        recordingFile = file
        recordingWhole = whole
        recordingLabel = target.gameIndex.map { "第\($0 + 1)ゲーム" } ?? (whole ? "通し録画" : "手動録画")
        recorder.startRecording(to: library.folder(of: index).appendingPathComponent(file), rotationAngle: Self.currentRotationAngle())
    }

    private func clipStarted(_ url: URL, at: Date) {
        guard let target = recording,
              var index = library.sessions.first(where: { $0.id == target.sessionId }) else { return }
        index.clips.append(.init(file: url.lastPathComponent, gameIndex: target.gameIndex, startedAt: at,
                                 wholeSession: recordingWhole ? true : nil))
        library.save(index)
        recordingStartedAt = at
        message = nil
    }

    private func clipFinished(_ url: URL, error: Error?) {
        if let target = recording, var index = library.sessions.first(where: { $0.id == target.sessionId }),
           let i = index.clips.firstIndex(where: { $0.file == url.lastPathComponent }) {
            index.clips[i].endedAt = Date()
            library.save(index)
        }
        if let error { message = "録画が途中で止まりました: \(error.localizedDescription)" }
        recording = nil
        recordingFile = nil
        recordingStartedAt = nil
        recordingLabel = ""
        manual = false
        if let next = restartAfterStop {
            restartAfterStop = nil
            startClip(next)
        } else if autoRecord, let s = client.snapshot, let target = autoTarget(s) {
            // 止めている間にゲームが始まっていたら追いかける
            startClip(target)
        }
    }

    // MARK: - 端末の状態

    private func thermalChanged() {
        thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .critical, recording != nil {
            message = "端末が熱くなりすぎたため録画を止めました。日陰に移す・ケースを外すなどしてください"
            autoRecord = false
            recorder.stopRecording()
        }
        recordSample()
    }

    private func updateDeviceStatus() {
        batteryLevel = UIDevice.current.batteryLevel
        let values = try? library.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        freeBytes = values?.volumeAvailableCapacityForImportantUsage
        if let free = freeBytes, free < Self.minimumFreeBytes, recording != nil {
            message = "空き容量が足りなくなったため録画を止めました"
            autoRecord = false
            pendingStop?.cancel()
            restartAfterStop = nil
            recorder.stopRecording()
        }
        recordSample()
    }

    private func recordSample() {
        let state = UIDevice.current.batteryState
        deviceLog.append(DeviceSample(
            at: Date(),
            thermal: DeviceSample.thermalLevel(thermalState),
            battery: batteryLevel >= 0 ? Int((batteryLevel * 100).rounded()) : nil,
            charging: state == .charging || state == .full,
            freeBytes: freeBytes,
            recording: recording != nil
        ))
    }

    /// 画面の向きに合わせた録画の向き（横向き専用アプリ）。
    static func currentRotationAngle() -> CGFloat {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: return 180
        default: return 0
        }
    }
}
