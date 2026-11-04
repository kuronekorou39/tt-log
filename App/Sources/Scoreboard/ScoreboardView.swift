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

    @AppStorage(ScoreboardTheme.storageKey) private var themeRaw = ScoreboardTheme.simple.rawValue
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
        case newSession, players, history, settings, design
        var id: String { rawValue }
    }

    private var theme: ScoreboardTheme { ScoreboardTheme(rawValue: themeRaw) ?? .simple }

    var body: some View {
        GeometryReader { proxy in
            let compact = proxy.size.width < 1000 || proxy.size.height < 500
            VStack(spacing: 0) {
                topBar(compact: compact)
                Divider()
                if let state = model.state {
                    ZStack {
                        ScoreboardDisplay(theme: theme, state: state,
                                          playerNames: [model.name(0), model.name(1)]) { player in
                            model.handle(.point(player: player), source: .tap)
                        }
                        .accessibilityHidden(state.phase != .playing)
                        if state.phase != .playing {
                            gameOverOverlay(state)
                        }
                    }
                    Divider()
                    if compact {
                        bottomBar(state, compact: true).labelStyle(.iconOnly)
                    } else {
                        bottomBar(state, compact: false)
                    }
                } else {
                    idleView
                }
            }
            .background(theme.background)
            .foregroundStyle(theme.foreground)
        }
        .preferredColorScheme(theme.colorScheme)
        .sheet(item: $sheet) { s in
            switch s {
            case .newSession: NewSessionView { players, config in model.start(players: players, config: config) }
            case .players: NavigationStack { PlayersView() }
            case .history: NavigationStack { HistoryView() }
            case .settings: ScoreboardSettingsView(listener: model.listener, onChangeRole: onChangeRole)
            case .design:
                ScoreboardDesignSheet(state: model.state,
                                      playerNames: model.state == nil ? ["プレーヤー A", "プレーヤー B"] : [model.name(0), model.name(1)])
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

    private func topBar(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 14) {
            if let state = model.state {
                if !compact {
                    Text("今日 \(model.name(state.left)) \(state.gamesWon[state.left]) - \(state.gamesWon[1 - state.left]) \(model.name(1 - state.left))")
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("第\(state.gameIndex + 1)ゲーム")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if state.switchedEndsMidGame, max(state.scores[0], state.scores[1]) == 5 {
                    Text("エンドチェンジ")
                        .font(.headline)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            } else {
                Text("TTLog").font(.headline)
            }
            Spacer()
            if compact {
                CameraBadge(server: model.server).labelStyle(.iconOnly)
            } else {
                CameraBadge(server: model.server)
            }
            MicButton(listener: model.listener)
            Button { sheet = .design } label: {
                Image(systemName: "paintpalette")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("スコアボードのデザイン")
            .accessibilityValue(theme.title)
            Menu {
                Button { sheet = .newSession } label: { Label("新しい記録", systemImage: "plus") }
                Button { sheet = .players } label: { Label("選手", systemImage: "person.2") }
                Button { sheet = .history } label: { Label("履歴", systemImage: "clock") }
                Button { sheet = .design } label: { Label("デザイン", systemImage: "paintpalette") }
                Button { sheet = .settings } label: { Label("設定", systemImage: "gearshape") }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title2)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("メニュー")
        }
        .padding(.horizontal)
        .padding(.vertical, compact ? 0 : 4)
    }

    // MARK: - 得点の面

    private func gameOverOverlay(_ state: MatchState) -> some View {
        let winner: Int
        let matchOver: Bool
        switch state.phase {
        case .gameOver(let w): winner = w; matchOver = false
        case .matchOver(let w): winner = w; matchOver = true
        case .playing: winner = 0; matchOver = false
        }
        return GeometryReader { proxy in
            let compact = proxy.size.height < 380
            VStack(spacing: compact ? 8 : 16) {
                Text("\(model.name(winner)) \(matchOver ? "の勝ち（試合終了）" : "勝ち")")
                    .font(.system(size: compact ? 28 : 52, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Text("\(state.scores[winner]) - \(state.scores[1 - winner])")
                    .font(.system(size: compact ? 28 : 48, weight: .semibold, design: .rounded))
                if matchOver {
                    Button("記録を終える") { model.end() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                } else {
                    Button {
                        model.handle(.nextGame, source: .tap)
                    } label: {
                        Text("次のゲーム")
                            .font(compact ? .headline : .title.bold())
                            .padding(.horizontal, 24)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    if !compact {
                        Text("「次のゲーム」と言っても始められます。始めると左右が入れ替わります。")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .padding(compact ? 16 : 32)
            .frame(maxWidth: min(760, max(0, proxy.size.width - 32)))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(theme.background.opacity(0.65))
        }
    }

    private func bottomBar(_ state: MatchState, compact: Bool) -> some View {
        HStack {
            Button {
                model.handle(.undo, source: .tap)
            } label: {
                Label("戻す", systemImage: "arrow.uturn.backward").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.log?.events.isEmpty ?? true)
            .accessibilityLabel("戻す")
            Button {
                model.redo()
            } label: {
                Label("やり直し", systemImage: "arrow.uturn.forward").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(model.redoStack.isEmpty)
            .accessibilityLabel("やり直し")
            Spacer()
            Button {
                model.toggleServer()
            } label: {
                Label("サーブ交代", systemImage: "circle.lefthalf.filled").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(state.phase != .playing)
            .accessibilityLabel("サーブ交代")
            Button {
                model.swapEnds()
            } label: {
                Label("左右入れ替え", systemImage: "arrow.left.arrow.right").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("左右入れ替え")
            Spacer()
            PartialTextView(listener: model.listener)
                .font(compact ? .caption : .body)
                .frame(maxWidth: compact ? 160 : 240)
                .layoutPriority(-1)
            Spacer()
            Button(role: .destructive) {
                showEndConfirm = true
            } label: {
                Label("終了", systemImage: "stop.circle").font(.title3)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityLabel("記録を終了")
        }
        .padding(.horizontal)
        .padding(.vertical, compact ? 4 : 10)
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
