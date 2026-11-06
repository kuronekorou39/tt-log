import AVFoundation
import SwiftUI
import TTLogCore
import UIKit

/// カメラ端末（iPhone を三脚に固定する想定）。
struct CameraView: View {
    let onChangeRole: () -> Void

    @StateObject private var controller = CameraController()
    @AppStorage("camera.manualHost") private var manualHost = ""
    @State private var showConnect = false
    @State private var showLibrary = false

    var body: some View {
        ZStack {
            CameraPreview(session: controller.recorder.session)
                .ignoresSafeArea()
            VStack {
                CameraTopBar(controller: controller, client: controller.client, recorder: controller.recorder)
                Spacer()
                CameraBottomBar(
                    controller: controller, recorder: controller.recorder,
                    onConnect: { showConnect = true },
                    onLibrary: { showLibrary = true },
                    onChangeRole: onChangeRole
                )
            }
            .padding()
        }
        .task {
            UIApplication.shared.isIdleTimerDisabled = true
            await controller.start(manualHost: manualHost)
        }
        .sheet(isPresented: $showConnect) {
            ConnectSheet(manualHost: $manualHost) {
                controller.client.start(manualHost: manualHost)
            }
        }
        .fullScreenCover(isPresented: $showLibrary) {
            NavigationStack {
                LibraryView(library: controller.library, deviceLog: controller.deviceLog)
            }
        }
    }
}

// MARK: - 上の帯（接続・スコア・端末の状態）

private struct CameraTopBar: View {
    @ObservedObject var controller: CameraController
    @ObservedObject var client: PeerClient
    @ObservedObject var recorder: CameraRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Label(client.status.title, systemImage: client.status.isConnected ? "link" : "link.badge.plus")
                    .foregroundStyle(client.status.isConnected ? Color.green : Color.orange)
                if let s = client.snapshot, s.sessionId != nil {
                    Text(scoreText(s))
                }
                Spacer()
                if controller.recordingStartedAt != nil {
                    RecordingBadge(startedAt: controller.recordingStartedAt, label: controller.recordingLabel)
                }
            }
            HStack(spacing: 14) {
                Text(recorder.formatDescription)
                thermalLabel
                if controller.batteryLevel >= 0 {
                    Label("\(Int(controller.batteryLevel * 100))%", systemImage: "battery.75")
                }
                if let free = controller.freeBytes {
                    Label("空き \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))", systemImage: "internaldrive")
                        .foregroundStyle(free < CameraController.lowFreeBytes ? Color.orange : Color.primary)
                }
                if let offset = client.clockOffsetMs {
                    Text("時計のずれ \(Int(offset))ms").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            if let m = controller.message ?? recorder.errorMessage {
                Text(m).font(.callout).foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }

    private func scoreText(_ s: ScoreboardSnapshot) -> String {
        let a = s.playerNames.first ?? "A"
        let b = s.playerNames.count > 1 ? s.playerNames[1] : "B"
        let phase: String
        switch s.phase {
        case .playing: phase = ""
        case .gameOver: phase = "（ゲーム終了）"
        case .matchOver: phase = "（試合終了）"
        case .idle: phase = ""
        }
        return "第\(s.gameIndex + 1)ゲーム \(a) \(s.scores[0]) - \(s.scores[1]) \(b)\(phase)"
    }

    private var thermalLabel: some View {
        let (text, color): (String, Color) = {
            switch controller.thermalState {
            case .nominal: return ("温度 正常", .white)
            case .fair: return ("温度 やや高い", .white)
            case .serious: return ("温度 高い", .orange)
            case .critical: return ("温度 危険", .red)
            @unknown default: return ("温度 ?", .white)
            }
        }()
        return Label(text, systemImage: "thermometer.medium").foregroundStyle(color)
    }
}

private struct RecordingBadge: View {
    let startedAt: Date?
    let label: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = Int(context.date.timeIntervalSince(startedAt ?? context.date))
            Label("\(label) \(elapsed / 60):\(String(format: "%02d", elapsed % 60))", systemImage: "record.circle")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.red)
        }
    }
}

// MARK: - 下の帯（操作）

private struct CameraBottomBar: View {
    @ObservedObject var controller: CameraController
    @ObservedObject var recorder: CameraRecorder
    let onConnect: () -> Void
    let onLibrary: () -> Void
    let onChangeRole: () -> Void

    private enum Mode {
        case perGame, whole, off

        var title: String {
            switch self {
            case .perGame: return "自動録画：ゲームごと"
            case .whole: return "自動録画：記録中ずっと"
            case .off: return "自動録画：OFF"
            }
        }
    }

    private var mode: Mode {
        guard controller.autoRecord else { return .off }
        return controller.recordWholeSession ? .whole : .perGame
    }

    private var modeBinding: Binding<Mode> {
        Binding(get: { mode }, set: { newMode in
            switch newMode {
            case .perGame:
                controller.autoRecord = true
                controller.recordWholeSession = false
            case .whole:
                controller.autoRecord = true
                controller.recordWholeSession = true
            case .off:
                controller.autoRecord = false
            }
        })
    }

    var body: some View {
        HStack(spacing: 16) {
            Menu {
                // メニューの中の Picker は、選んでいるものにチェックが付く
                Picker("自動録画", selection: modeBinding) {
                    Text("ゲームごとに録画").tag(Mode.perGame)
                    Text("記録中ずっと録画").tag(Mode.whole)
                    Text("自動録画しない").tag(Mode.off)
                }
            } label: {
                Label(mode.title, systemImage: "record.circle")
                    .fixedSize()
            }
            Spacer()
            Button {
                controller.toggleManualRecording()
            } label: {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
            }
            .disabled(!recorder.isRunning)
            Spacer()
            Button("接続", action: onConnect)
            Button("振り返り", action: onLibrary)
            Menu {
                Button("役割を変える", action: onChangeRole)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .buttonStyle(.bordered)
        .padding(10)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

private struct ConnectSheet: View {
    @Binding var manualHost: String
    let onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例 172.20.10.2（空欄なら自動で探す）", text: $manualHost)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("スコアボードの IP アドレス")
                } footer: {
                    Text("ふつうは空欄のままで、同じ Wi-Fi（テザリングでもよい）にいるスコアボードを自動で見つけます。見つからないときは、スコアボードの画面に出ている IP アドレスを入れてください。")
                }
            }
            .navigationTitle("接続")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("つなぐ") {
                        onApply()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - プレビュー

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            let angle = CameraController.currentRotationAngle()
            if let conn = previewLayer.connection, conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
        }
    }
}
