import SwiftUI
import TTLogCore
import UIKit

/// 音声認識の試作画面。体育館で「聞き取れるか」「誤反応しないか」を確かめるためのもの。
///
/// 左右の大きな数字は簡易スコア（ルールエンジンはまだ入れていない）。
/// 下のログに、聞き取った文・読み・結果を残す。ログは共有ボタンで送れる。
struct VoiceTestView: View {
    @StateObject private var listener = SpeechListener()
    @State private var tones = TonePlayer()
    @State private var points: [Int] = []          // 得点した選手の番号の並び（Undo 用）
    @State private var finishedGames: [[Int]] = [] // 「次のゲーム」で区切った過去のゲーム
    @State private var showSettings = false

    // 実名をコードに書かないため、既定値は空。設定画面で登録する。
    @AppStorage("player0.name") private var name0 = ""
    @AppStorage("player0.callName") private var callName0 = ""
    @AppStorage("player1.name") private var name1 = ""
    @AppStorage("player1.callName") private var callName1 = ""
    @AppStorage("voice.deadTime") private var deadTime = 1.5
    @AppStorage("voice.silenceMs") private var silenceMs = 600
    @AppStorage("sound.volume") private var volume = 0.3
    @AppStorage("sound.enabled") private var soundEnabled = true

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
                ShareLink(item: listener.logText()) { Image(systemName: "square.and.arrow.up") }
                Button("ログ消去") { listener.clearLog() }
            }
            .buttonStyle(.bordered)
            List(listener.log) { u in
                HStack {
                    Text(u.time, format: .dateTime.hour().minute().second())
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Text(u.text)
                    Text("（\(u.reading)）")
                        .foregroundStyle(.secondary)
                    Spacer()
                    resultLabel(u)
                }
                .font(.callout)
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

    private func applySettings() {
        listener.matcher = VoiceCommandMatcher(playerCallNames: callNames)
        listener.contextualStrings = callNames.filter { !$0.isEmpty } + ["戻して", "次のゲーム"]
        listener.gate.deadTime = deadTime
        listener.silenceInterval = .milliseconds(silenceMs)
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
