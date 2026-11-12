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
///
/// 録画が止まっても思い込まない（2026-11-12 の練習で、一瞬の中断のあと1時間撮れていなかった）：
/// - 録画を始められなかったら、少し待って撮り直す
/// - 止めようとしたら録画していなかった、という場合も次の録画に進む
/// - 頼んでから始まらない・書き込みが進まないときは、撮り直す
/// - 録画の状態は2秒ごとにスコアボードへ送る（スコアボードに「録画中」かどうかを出す）
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
    private var liveTimer: Timer?
    /// 録画を頼んだ時刻。始まらないまま時間がたったら撮り直す。
    private var requestedAt: Date?
    /// 最後にファイルが大きくなった時刻。
    private var lastGrowthAt: Date?
    private var lastBytes: Int64 = 0
    /// スコアボードに出す、録画できていない理由。
    private var problem: String?

    static let postRollSeconds = 3
    /// 空きがこれより少なければ録画を始めない。
    static let minimumFreeBytes: Int64 = 1_000_000_000
    /// 空きがこれより少なければ注意を出す。
    static let lowFreeBytes: Int64 = 5_000_000_000
    /// 頼んでからこれだけたっても始まらなければ、撮り直す。
    static let startTimeoutSeconds = 6.0
    /// ファイルがこれだけ大きくならなければ、書き込みが止まったとみなす。
    static let stallSeconds = 25.0
    static let retrySeconds = 3

    init() {
        recorder.onStarted = { [weak self] url, at in self?.clipStarted(url, at: at) }
        recorder.onFinished = { [weak self] url, error in self?.clipFinished(url, error: error) }
        recorder.onStartFailed = { [weak self] reason in self?.startFailed(reason) }
        recorder.onStopWithoutRecording = { [weak self] in self?.stoppedWithoutRecording() }
        recorder.onResumed = { [weak self] in self?.resume() }
        recorder.onEvent = { [weak self] text in self?.note(text) }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        })
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
        liveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveTick() }
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
            problem = "空き容量が足りません"
            manual = false
            return
        }
        if thermalState == .critical {
            message = "端末が熱くなりすぎているため録画を始めません"
            problem = "カメラが熱すぎます"
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
        requestedAt = Date()
        recordingLabel = target.gameIndex.map { "第\($0 + 1)ゲーム" } ?? (whole ? "通し録画" : "手動録画")
        recorder.startRecording(to: library.folder(of: index).appendingPathComponent(file), rotationAngle: Self.currentRotationAngle())
    }

    private func clipStarted(_ url: URL, at: Date) {
        guard recording != nil else {
            // 撮り直しを決めたあとで遅れて始まった録画。持ち主がいないので止める
            note("持ち主のない録画を止めた")
            recorder.stopRecording()
            return
        }
        requestedAt = nil
        lastGrowthAt = at
        lastBytes = 0
        problem = nil
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
        if let error {
            message = "録画が途中で止まりました: \(error.localizedDescription)"
            problem = "録画が止まりました"
            note("録画が止まった: \(error.localizedDescription)")
        }
        afterStop()
    }

    /// 録画が終わったあと（終わっていた場合も含む）。次に撮るものがあれば始める。
    private func afterStop() {
        clearRecording()
        if let next = restartAfterStop {
            restartAfterStop = nil
            startClip(next)
        } else if autoRecord, let s = client.snapshot, let target = autoTarget(s) {
            // 止めている間にゲームが始まっていたら追いかける
            startClip(target)
        }
    }

    private func clearRecording() {
        recording = nil
        recordingFile = nil
        recordingStartedAt = nil
        recordingLabel = ""
        requestedAt = nil
        lastGrowthAt = nil
        manual = false
    }

    private func startFailed(_ reason: String) {
        note("録画を始められない: \(reason)")
        problem = "録画できていません（\(reason)）"
        restartAfterStop = nil
        clearRecording()
        retryLater()
    }

    private func stoppedWithoutRecording() {
        guard recording != nil else { return }
        note("止める録画がなかった")
        afterStop()
    }

    /// 少し待ってから、いま撮るべきものを撮り直す。
    private func retryLater() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            self?.resume()
        }
    }

    /// カメラやアプリが戻ってきたとき。撮るべきなのに撮っていなければ始める。
    private func resume() {
        guard recording == nil else { return }
        handle(client.snapshot)
    }

    /// 2秒ごと：録画が本当に進んでいるかを確かめ、状態をスコアボードへ送る。
    private func liveTick() {
        let now = Date()
        if recording != nil {
            if recorder.isRecording {
                if recorder.recordedBytes > lastBytes {
                    lastBytes = recorder.recordedBytes
                    lastGrowthAt = now
                } else if let grew = lastGrowthAt, now.timeIntervalSince(grew) > Self.stallSeconds {
                    note("書き込みが止まったので撮り直す")
                    problem = "録画が止まりました"
                    lastGrowthAt = now
                    recorder.stopRecording()
                }
            } else if let asked = requestedAt, now.timeIntervalSince(asked) > Self.startTimeoutSeconds {
                startFailed("始まらない")
            }
        }
        client.send(currentStatus(now))
    }

    private func currentStatus(_ now: Date) -> CameraStatus {
        let writing = recorder.isRecording && lastGrowthAt.map { now.timeIntervalSince($0) <= Self.stallSeconds } == true
        return CameraStatus(
            recording: writing,
            clipSeconds: writing ? recordingStartedAt.map { now.timeIntervalSince($0) } : nil,
            problem: problem,
            battery: batteryLevel >= 0 ? Int((batteryLevel * 100).rounded()) : nil,
            thermal: DeviceSample.thermalLevel(thermalState),
            sentAt: now.epochMilliseconds
        )
    }

    /// 原因を追えるよう、出来事を端末ログに残す。
    private func note(_ text: String) {
        recordSample(note: text)
    }

    // MARK: - 端末の状態

    private func thermalChanged() {
        thermalState = ProcessInfo.processInfo.thermalState
        if thermalState == .critical, recording != nil {
            message = "端末が熱いので録画を止めました"
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

    private func recordSample(note: String? = nil) {
        let state = UIDevice.current.batteryState
        deviceLog.append(DeviceSample(
            at: Date(),
            thermal: DeviceSample.thermalLevel(thermalState),
            battery: batteryLevel >= 0 ? Int((batteryLevel * 100).rounded()) : nil,
            charging: state == .charging || state == .full,
            freeBytes: freeBytes,
            recording: recorder.isRecording,
            note: note
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
