import Foundation
import Speech
import SwiftData
import TTLogCore

/// スコアボードの中心。いまの記録を持ち、操作を反映して保存し、カメラへ状態を送る。
@MainActor
final class ScoreboardModel: ObservableObject {
    enum VoiceMode: String, CaseIterable {
        /// 画面の左右を指す言葉で呼ぶ（既定）。エンドが入れ替わっても言葉は立ち位置のまま。
        case sides
        /// 選手ごとの呼び名で呼ぶ。
        case playerNames

        var title: String {
            switch self {
            case .sides: return "画面の左右の言葉"
            case .playerNames: return "選手の呼び名"
            }
        }
    }

    @Published private(set) var session: SessionRecord?
    @Published private(set) var log: SessionLog?
    @Published private(set) var state: MatchState?
    @Published private(set) var players: [PlayerRecord] = []
    /// 「戻す」で取り消した操作（新しい操作をしたら捨てる）。
    @Published private(set) var redoStack: [TimedEvent] = []

    let server = PeerServer()
    let listener = SpeechListener()
    let tones = TonePlayer()

    var soundEnabled = true
    var voiceMode = VoiceMode.sides { didSet { updateVoiceWords() } }
    var leftWord = "ひだり" { didSet { updateVoiceWords() } }
    var rightWord = "みぎ" { didSet { updateVoiceWords() } }

    private var context: ModelContext?

    func attach(_ context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context
        listener.onCommand = { [weak self] command in self?.handle(command, source: .voice) }
        listener.onRejected = { [weak self] _ in self?.playTone(.rejected) }
        listener.onUnmatched = { [weak self] reading in self?.handleScoreCall(reading) }
        server.start()
        resumeOrSplit()
    }

    /// 終わっていない記録を引き継ぐ。日付が変わっていたら区切る（押し忘れ対策）。
    func resumeOrSplit() {
        guard let context else { return }
        let open = (try? context.fetch(FetchDescriptor<SessionRecord>(
            predicate: #Predicate { $0.endedAt == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))) ?? []
        for s in open {
            if session == nil, Calendar.current.isDateInToday(s.startedAt) {
                load(s)
            } else if s.id != session?.id {
                s.endedAt = s.log.events.last?.at ?? s.startedAt
            }
        }
        if let s = session, !Calendar.current.isDateInToday(s.startedAt) {
            end()
        }
        try? context.save()
        refresh()
    }

    func start(players: [PlayerRecord], config: MatchConfig) {
        guard let context, players.count == 2 else { return }
        if session != nil { end() }
        let record = SessionRecord(players: players, log: SessionLog(config: config, startedAt: Date()))
        context.insert(record)
        try? context.save()
        load(record)
        playTone(.nextGame)
    }

    /// 記録を終える。
    func end() {
        guard let session else { return }
        session.endedAt = Date()
        try? context?.save()
        self.session = nil
        log = nil
        state = nil
        players = []
        refresh()
    }

    func handle(_ command: VoiceCommand, source: InputSource) {
        guard var log else { return }
        let now = Date()
        switch command {
        case .point(let p):
            guard log.append(.point(winner: p), at: now, source: source) else {
                playTone(.rejected)
                return
            }
            playTone(log.state.phase == .playing ? .point : .gameOver)
        case .undo:
            guard let undone = log.popLast() else { return }
            redoStack.append(undone)
            playTone(.undo)
            commit(log, keepRedo: true)
            return
        case .nextGame:
            guard log.append(.startNextGame, at: now, source: source) else {
                playTone(.rejected)
                return
            }
            playTone(.nextGame)
        }
        commit(log)
    }

    /// 「戻す」で取り消した操作をやり直す。
    func redo() {
        guard var log, let event = redoStack.last else { return }
        guard log.redo(event) else {
            redoStack.removeAll()
            playTone(.rejected)
            return
        }
        redoStack.removeLast()
        playTone(.redo)
        commit(log, keepRedo: true)
    }

    /// いまのサーバーを入れ替える。
    func toggleServer() {
        guard var log else { return }
        log.toggleServer()
        playTone(.confirm)
        commit(log, keepRedo: true)
    }

    /// 画面の左右（立ち位置）を入れ替える。
    func swapEnds() {
        guard var log else { return }
        log.swapEnds()
        playTone(.confirm)
        commit(log, keepRedo: true)
    }

    /// 口で言ったスコア（「ななきゅう」など）を反映する。受け付けたら説明を返す。
    private func handleScoreCall(_ reading: String) -> String? {
        guard var log else { return nil }
        let pairs = ScoreCallParser.pairs(in: reading)
        guard !pairs.isEmpty else { return nil }
        guard let resolution = ScoreCallResolver.resolve(pairs: pairs, log: log) else {
            playTone(.rejected)
            return nil
        }
        let now = Date()
        switch resolution {
        case .confirm:
            playTone(.confirm)
            return "スコア確認"
        case .undo:
            handle(.undo, source: .voice)
            return "スコアから取り消し"
        case .points(let p, let count):
            for _ in 0..<count { log.append(.point(winner: p), at: now, source: .voice) }
            playTone(log.state.phase == .playing ? .point : .gameOver)
            commit(log)
            let s = log.state.scores
            return "スコア \(s[0])-\(s[1])（\(name(p)) +\(count)）"
        }
    }

    /// 画面に出す名前。
    func name(_ player: Int) -> String {
        if let session, player < session.playerNames.count { return session.playerNames[player] }
        return player == 0 ? "A" : "B"
    }

    // MARK: -

    private func load(_ record: SessionRecord) {
        session = record
        let ids = record.playerIDs
        let all = (try? context?.fetch(FetchDescriptor<PlayerRecord>())) ?? []
        players = ids.compactMap { id in all.first { $0.id == id } }
        commit(record.log, save: false)
    }

    private func commit(_ newLog: SessionLog, save: Bool = true, keepRedo: Bool = false) {
        if !keepRedo { redoStack.removeAll() }
        log = newLog
        state = newLog.state
        session?.log = newLog
        if save { try? context?.save() }
        refresh()
    }

    /// 音声の言葉とカメラへの送信を、いまの状態に合わせる。
    private func refresh() {
        updateVoiceWords()
        if let session, let log {
            server.broadcast(log.snapshot(sessionId: session.id.uuidString, playerNames: session.playerNames, now: Date()))
        } else {
            server.broadcast(.idle(sentAt: Date().epochMilliseconds))
        }
    }

    private func updateVoiceWords() {
        let words: [String]
        switch voiceMode {
        case .sides:
            // 選手の番号順に、その選手がいま立っている側の言葉を並べる
            let left = state?.left ?? 0
            words = [0, 1].map { $0 == left ? leftWord : rightWord }
        case .playerNames:
            words = [0, 1].map { p in p < players.count ? players[p].callName : "" }
        }
        listener.matcher = VoiceCommandMatcher(playerCallNames: words)
        listener.contextualStrings = words.filter { !$0.isEmpty } + ["戻して", "次のゲーム"]
    }

    private func playTone(_ kind: TonePlayer.Kind) {
        if soundEnabled { tones.play(kind) }
    }
}
