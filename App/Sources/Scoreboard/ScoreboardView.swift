import Speech
import SwiftData
import SwiftUI
import TTLogCore
import UIKit

/// スコアボード（iPad を台の横に置く想定）。
///
/// 画面の左右 = 台の側から画面を見たときの2人の立ち位置。エンドチェンジのたびに入れ替わる。
struct ScoreboardView: View {
    let onChangeRole: () -> Void

    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = ScoreboardModel()

    @State private var sheet: Sheet?
    @State private var showEndConfirm = false

    @AppStorage("sound.enabled") private var soundEnabled = true
    @AppStorage("sound.volume") private var volume = 0.3
    @AppStorage("voice.mode") private var voiceMode = ScoreboardModel.VoiceMode.sides.rawValue
    @AppStorage("voice.leftWord") private var leftWord = "ひだり"
    @AppStorage("voice.rightWord") private var rightWord = "みぎ"
    @AppStorage("voice.deadTime") private var deadTime = 1.5
    @AppStorage("voice.silenceMs") private var silenceMs = 600
    @AppStorage("voice.recordsAudio") private var recordsAudio = true
    @AppStorage("voice.taskHint") private var taskHint = SFSpeechRecognitionTaskHint.confirmation.rawValue

    enum Sheet: String, Identifiable {
        case newSession, players, history, settings
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let state = model.state {
                ZStack {
                    HStack(spacing: 0) {
                        panel(player: state.left, state: state)
                        Divider()
                        panel(player: 1 - state.left, state: state)
                    }
                    if state.phase != .playing {
                        gameOverOverlay(state)
                    }
                }
                Divider()
                bottomBar(state)
            } else {
                idleView
            }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .newSession: NewSessionView { players, config in model.start(players: players, config: config) }
            case .players: NavigationStack { PlayersView() }
            case .history: NavigationStack { HistoryView() }
            case .settings: ScoreboardSettingsView(listener: model.listener, onChangeRole: onChangeRole)
            }
        }
        .confirmationDialog("記録を終えますか？", isPresented: $showEndConfirm, titleVisibility: .visible) {
            Button("終える", role: .destructive) { model.end() }
        } message: {
            Text("終えた記録は履歴から見られます。")
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            model.attach(context)
            applySettings()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resumeOrSplit() }
        }
        .onChange(of: settingsKey) { applySettings() }
    }

    // MARK: - 上の帯

    private var topBar: some View {
        HStack(spacing: 14) {
            if let state = model.state {
                Text("今日 \(model.name(state.left)) \(state.gamesWon[state.left]) - \(state.gamesWon[1 - state.left]) \(model.name(1 - state.left))")
                    .font(.headline)
                Text("第\(state.gameIndex + 1)ゲーム")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                if state.switchedEndsMidGame, max(state.scores[0], state.scores[1]) == 5 {
                    Text("エンドチェンジ")
                        .font(.headline)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("TTLog").font(.headline)
            }
            Spacer()
            CameraBadge(server: model.server)
            MicButton(listener: model.listener)
            Menu {
                Button { sheet = .newSession } label: { Label("新しい記録", systemImage: "plus") }
                Button { sheet = .players } label: { Label("選手", systemImage: "person.2") }
                Button { sheet = .history } label: { Label("履歴", systemImage: "clock") }
                Button { sheet = .settings } label: { Label("設定", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title2)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - 得点の面

    private func panel(player: Int, state: MatchState) -> some View {
        Button {
            model.handle(.point(player: player), source: .tap)
        } label: {
            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    if state.server == player {
                        Circle().fill(.orange).frame(width: 18, height: 18)
                    }
                    Text(model.name(player))
                        .font(.system(size: 44, weight: .bold))
                }
                Text("\(state.scores[player])")
                    .font(.system(size: 320, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.3)
                    .lineLimit(1)
                Text(state.server == player ? "サーブ" : " ")
                    .font(.title3)
                    .foregroundStyle(.orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(state.phase != .playing)
    }

    private func gameOverOverlay(_ state: MatchState) -> some View {
        let winner: Int
        let matchOver: Bool
        switch state.phase {
        case .gameOver(let w): winner = w; matchOver = false
        case .matchOver(let w): winner = w; matchOver = true
        case .playing: winner = 0; matchOver = false
        }
        return VStack(spacing: 16) {
            Text("\(model.name(winner)) \(matchOver ? "の勝ち（試合終了）" : "勝ち")")
                .font(.system(size: 64, weight: .bold))
            Text("\(state.scores[winner]) - \(state.scores[1 - winner])")
                .font(.system(size: 48, weight: .semibold, design: .rounded))
            if matchOver {
                Button("記録を終える") { model.end() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            } else {
                Button {
                    model.handle(.nextGame, source: .tap)
                } label: {
                    Text("次のゲーム").font(.title.bold()).padding(.horizontal, 24)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Text("「次のゲーム」と言っても始められます。始めると左右が入れ替わります。")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    }

    private func bottomBar(_ state: MatchState) -> some View {
        HStack {
            Button {
                model.handle(.undo, source: .tap)
            } label: {
                Label("戻す", systemImage: "arrow.uturn.backward").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.log?.events.isEmpty ?? true)
            Button {
                model.redo()
            } label: {
                Label("やり直し", systemImage: "arrow.uturn.forward").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.redoStack.isEmpty)
            Spacer()
            Button {
                model.toggleServer()
            } label: {
                Label("サーブ交代", systemImage: "circle.lefthalf.filled").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(state.phase != .playing)
            Button {
                model.swapEnds()
            } label: {
                Label("左右入れ替え", systemImage: "arrow.left.arrow.right").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            Spacer()
            PartialTextView(listener: model.listener)
            Spacer()
            Button(role: .destructive) {
                showEndConfirm = true
            } label: {
                Label("終了", systemImage: "stop.circle").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private var idleView: some View {
        VStack(spacing: 20) {
            Spacer()
            Button {
                sheet = .newSession
            } label: {
                Label("記録を始める", systemImage: "play.fill")
                    .font(.largeTitle.bold())
                    .padding(.horizontal, 30)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            HStack(spacing: 16) {
                Button("選手") { sheet = .players }
                Button("履歴") { sheet = .history }
                Button("設定") { sheet = .settings }
            }
            .buttonStyle(.bordered)
            Spacer()
            ConnectionHelp(server: model.server)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }

    // MARK: - 設定の反映

    private var settingsKey: [String] {
        [String(soundEnabled), String(volume), voiceMode, leftWord, rightWord, String(deadTime),
         String(silenceMs), String(recordsAudio), String(taskHint)]
    }

    private func applySettings() {
        model.soundEnabled = soundEnabled
        model.tones.volume = Float(volume)
        model.voiceMode = ScoreboardModel.VoiceMode(rawValue: voiceMode) ?? .sides
        model.leftWord = leftWord
        model.rightWord = rightWord
        model.listener.gate.deadTime = deadTime
        model.listener.silenceInterval = .milliseconds(silenceMs)
        model.listener.recordsAudio = recordsAudio
        model.listener.taskHint = SFSpeechRecognitionTaskHint(rawValue: taskHint) ?? .confirmation
    }
}

// モデルの中のオブジェクトの変化は、モデル経由では画面に伝わらないので、直接見る部品に分ける。

private struct CameraBadge: View {
    @ObservedObject var server: PeerServer

    var body: some View {
        let names = server.cameraNames
        Label(names.isEmpty ? "カメラ未接続" : "カメラ \(names.count)台",
              systemImage: names.isEmpty ? "video.slash" : "video.fill")
            .font(.callout)
            .foregroundStyle(names.isEmpty ? Color.secondary : Color.green)
    }
}

private struct MicButton: View {
    @ObservedObject var listener: SpeechListener

    var body: some View {
        Button {
            if listener.isListening {
                listener.stop()
            } else {
                Task { await listener.start() }
            }
        } label: {
            Label(listener.isListening ? "声 ON" : "声 OFF",
                  systemImage: listener.isListening ? "mic.fill" : "mic.slash")
        }
        .buttonStyle(.bordered)
        .tint(listener.isListening ? .green : .secondary)
    }
}

private struct PartialTextView: View {
    @ObservedObject var listener: SpeechListener

    var body: some View {
        if !listener.partialText.isEmpty {
            Text("聞き取り中: \(listener.partialText)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if !listener.statusMessage.isEmpty, listener.isListening == false {
            Text(listener.statusMessage)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ConnectionHelp: View {
    @ObservedObject var server: PeerServer

    var body: some View {
        let ips = NetworkInfo.localIPv4Addresses()
        VStack(spacing: 4) {
            Text("カメラ端末との接続: \(server.statusMessage)")
            if !ips.isEmpty {
                Text("自動で見つからないときは、カメラ側で次の IP アドレスを入力: \(ips.joined(separator: " / "))")
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
