import AVFoundation
import Speech
import SwiftUI
import TTLogCore
import UIKit

/// 音声認識の試作画面。体育館で「聞き取れるか」「誤反応しないか」を確かめるためのもの。
///
/// 左右の大きな数字は簡易スコア（ルールエンジンはまだ入れていない）。
/// 下のログに、聞き取った文・読み・結果を残す。音声もファイルに残し、zip で書き出せる。
/// 停止中にログの行をタップすると、その発話の音声を再生する。
struct VoiceTestView: View {
    @StateObject private var listener = SpeechListener()
    @State private var tones = TonePlayer()
    @State private var points: [Int] = []          // 得点した選手の番号の並び（Undo 用）
    @State private var finishedGames: [[Int]] = [] // 「次のゲーム」で区切った過去のゲーム
    @State private var showSettings = false
    @State private var exportURL: URL?
    @State private var exportError: String?
    @State private var showClearConfirm = false
    @State private var audioPlayer: AVAudioPlayer?

    // 実名をコードに書かないため、既定値は空。設定画面で登録する。
    @AppStorage("player0.name") private var name0 = ""
    @AppStorage("player0.callName") private var callName0 = ""
    @AppStorage("player1.name") private var name1 = ""
    @AppStorage("player1.callName") private var callName1 = ""
    @AppStorage("voice.deadTime") private var deadTime = 1.5
    @AppStorage("voice.silenceMs") private var silenceMs = 600
    @AppStorage("sound.volume") private var volume = 0.3
    @AppStorage("sound.enabled") private var soundEnabled = true
    @AppStorage("voice.recordsAudio") private var recordsAudio = true
    @AppStorage("voice.taskHint") private var taskHint = SFSpeechRecognitionTaskHint.confirmation.rawValue
    @AppStorage(MicMode.storageKey) private var micMode = MicMode.standard.rawValue

    private var callNames: [String] { [callName0, callName1] }
    private var needsSetup: Bool { callName0.isEmpty || callName1.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                scorePanel(player: 0)
                Divider()
                scorePanel(player: 1)
            }
            .frame(maxHeight: .infinity)
            Divider()
            logPanel
                .frame(height: 220)
        }
        .sheet(isPresented: $showSettings) {
            VoiceSettingsView()
        }
        .sheet(item: $exportURL) { url in
            ActivityView(items: [url])
        }
        .alert("書き出せませんでした", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog("ログと保存した音声をすべて消しますか？", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("消す", role: .destructive) { listener.clearLog() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            applySettings()
            listener.onCommand = { command in apply(command) }
            listener.onRejected = { _ in if soundEnabled { tones.play(.rejected) } }
            if needsSetup { showSettings = true }
        }
        .onChange(of: callNames) { applySettings() }
        .onChange(of: deadTime) { applySettings() }
        .onChange(of: silenceMs) { applySettings() }
        .onChange(of: volume) { applySettings() }
        .onChange(of: recordsAudio) { applySettings() }
        .onChange(of: taskHint) { applySettings() }
        .onChange(of: micMode) { applySettings() }
    }

    // MARK: - 上の帯

    private var topBar: some View {
        HStack(spacing: 16) {
            Text("ゲーム \(finishedGames.count + 1)")
                .font(.headline)
            if !finishedGames.isEmpty {
                Text("通算 \(gamesWon(0)) - \(gamesWon(1))")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Label(listener.supportsOnDevice ? "端末内認識 対応" : "端末内認識 未対応",
                  systemImage: listener.supportsOnDevice ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(listener.supportsOnDevice ? Color.green : Color.orange)
            Text(listener.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Label(listener.inputName, systemImage: "mic")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                if listener.isListening {
                    listener.stop()
                } else {
                    Task { await listener.start() }
                }
            } label: {
                Label(listener.isListening ? "停止" : "聞き取り開始",
                      systemImage: listener.isListening ? "mic.fill" : "mic.slash")
            }
            .buttonStyle(.borderedProminent)
            .tint(listener.isListening ? .red : .accentColor)
            .disabled(needsSetup)
            Button { showSettings = true } label: { Image(systemName: "gearshape") }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - スコア

    private func scorePanel(player: Int) -> some View {
        let name = displayName(player)
        return Button {
            apply(.point(player: player))
        } label: {
            VStack {
                Text(name)
                    .font(.largeTitle.bold())
                Text("\(score(player))")
                    .font(.system(size: 200, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                Text("呼び名: \(callNames[player].isEmpty ? "未設定" : callNames[player])")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - ログ

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("聞き取り中: \(listener.partialText)")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button("戻す") { apply(.undo) }
                Button("次のゲーム") { apply(.nextGame) }
                Button {
                    export()
                } label: {
                    Label("書き出し", systemImage: "square.and.arrow.up")
                }
                Button("ログ消去") { showClearConfirm = true }
            }
            .buttonStyle(.bordered)
            List(listener.log) { u in
                HStack {
                    Text(u.time, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if u.audioFile != nil {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                    }
                    Text(u.text)
                    Text("（\(u.reading)）")
                        .foregroundStyle(.secondary)
                    if !u.alternatives.isEmpty {
                        Text("他: \(u.alternatives.joined(separator: "／"))")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    resultLabel(u)
                }
                .font(.callout)
                .contentShape(Rectangle())
                .onTapGesture { play(u) }
            }
            .listStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.top, 6)
    }

    @ViewBuilder
    private func resultLabel(_ u: SpeechListener.Utterance) -> some View {
        if let c = u.command {
            let text = describe(c)
            if u.accepted {
                Text("○ \(text)").foregroundStyle(.green)
            } else {
                Text("× \(text)（二重）").foregroundStyle(.orange)
            }
        } else if u.accepted, let note = u.note {
            Text("○ \(note)").foregroundStyle(.green)
        } else {
            Text("－").foregroundStyle(.secondary)
        }
    }

    // MARK: - 操作

    private func apply(_ command: VoiceCommand) {
        switch command {
        case .point(let p):
            points.append(p)
            if soundEnabled { tones.play(.point) }
        case .undo:
            if !points.isEmpty {
                points.removeLast()
            } else if let last = finishedGames.popLast() {
                points = last // ゲームの区切りも取り消せる
            }
            if soundEnabled { tones.play(.undo) }
        case .nextGame:
            finishedGames.append(points)
            points = []
            if soundEnabled { tones.play(.nextGame) }
        }
    }

    private func export() {
        do {
            exportURL = try listener.store.exportArchive()
        } catch {
            exportError = "まだ記録がないか、zip を作れませんでした。（\(error.localizedDescription)）"
        }
    }

    /// 発話の音声を再生する。聞き取り中に鳴らすと自分で拾ってしまうので、停止中だけ。
    private func play(_ u: SpeechListener.Utterance) {
        guard !listener.isListening, let url = u.audioFile else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    private func applySettings() {
        listener.matcher = VoiceCommandMatcher(playerCallNames: callNames)
        listener.contextualStrings = SpeechListener.hints(callNames: callNames)
        listener.gate.deadTime = deadTime
        listener.silenceInterval = .milliseconds(silenceMs)
        listener.recordsAudio = recordsAudio
        listener.taskHint = SFSpeechRecognitionTaskHint(rawValue: taskHint) ?? .confirmation
        listener.micMode = MicMode(rawValue: micMode) ?? .standard
        listener.wordsSummary = callNames.joined(separator: "/")
        tones.volume = Float(volume)
    }

    private func score(_ player: Int) -> Int { points.filter { $0 == player }.count }

    private func gamesWon(_ player: Int) -> Int {
        finishedGames.filter { game in
            let mine = game.filter { $0 == player }.count
            return mine > game.count - mine
        }.count
    }

    private func displayName(_ player: Int) -> String {
        let n = player == 0 ? name0 : name1
        return n.isEmpty ? (player == 0 ? "A" : "B") : n
    }

    private func describe(_ c: VoiceCommand) -> String {
        switch c {
        case .point(let p): return "\(displayName(p)) に1点"
        case .undo: return "戻す"
        case .nextGame: return "次のゲーム"
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// 共有シート（AirDrop・メール・ファイルに保存 など）。
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
