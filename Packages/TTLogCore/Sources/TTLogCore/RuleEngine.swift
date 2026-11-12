/// 卓球（シングルス）のルールエンジン。
///
/// 試合の状態は保存せず、操作の列（`MatchEvent`）から毎回導く：
/// `state = RuleEngine.reduce(config, events)`。
/// 取り消しは「最後の操作を列から外して導き直す」だけで済む。
///
/// 選手は試合の中での番号（0 / 1）で扱う。誰が 0 番かは試合の記録側が持つ。

public enum MatchFormat: Hashable, Codable, Sendable {
    /// 1ゲームずつ、終わりを決めずに続ける（既定）。
    case continuous
    /// n ゲームマッチ（過半数を取ったら終了）。
    case bestOf(Int)
}

public struct MatchConfig: Hashable, Codable, Sendable {
    public var format: MatchFormat
    /// 第1ゲームで最初にサーブする選手。
    public var firstServer: Int
    /// 第1ゲームで画面の左側にいる選手。
    public var firstLeft: Int
    public var pointsToWin: Int

    public init(format: MatchFormat = .continuous, firstServer: Int = 0, firstLeft: Int = 0, pointsToWin: Int = 11) {
        self.format = format
        self.firstServer = firstServer
        self.firstLeft = firstLeft
        self.pointsToWin = pointsToWin
    }
}

public enum MatchEvent: Hashable, Codable, Sendable {
    case point(winner: Int)
    case startNextGame
    /// いまのゲームの得点を 0-0 に戻す（終わったゲームなら、終わる前に戻す）。
    case resetGame
}

public struct GameResult: Hashable, Codable, Sendable {
    public let scores: [Int]
    public let winner: Int
}

public struct MatchState: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        case playing
        /// ゲームが終わり、「次のゲーム」を待っている。
        case gameOver(winner: Int)
        /// ゲームマッチが終わった（連続形式では起きない）。
        case matchOver(winner: Int)
    }

    /// いま表示しているゲームの番号（0 始まり）。ゲーム終了後も、そのゲームを指したまま。
    public internal(set) var gameIndex = 0
    /// いま表示しているゲームの得点。ゲーム終了後は最終スコアのまま。
    public internal(set) var scores = [0, 0]
    public internal(set) var phase = Phase.playing
    public internal(set) var finishedGames: [GameResult] = []
    /// 画面の左側にいる選手。
    public internal(set) var left: Int
    /// いまのサーバー。ゲーム中でなければ nil。
    public internal(set) var server: Int?
    /// 最終ゲームの途中（5点）でエンドを入れ替えたか。
    public internal(set) var switchedEndsMidGame = false

    public var gamesWon: [Int] {
        [0, 1].map { p in finishedGames.filter { $0.winner == p }.count }
    }

    init(config: MatchConfig) {
        left = config.firstLeft
        server = config.firstServer
    }
}

public enum RuleEngine {
    public static func reduce(_ config: MatchConfig, _ events: [MatchEvent]) -> MatchState {
        var state = MatchState(config: config)
        for e in events {
            if let next = apply(e, to: state, config: config) { state = next }
        }
        return state
    }

    /// 操作を1つ反映した状態を返す。いまの状態で受け付けない操作なら nil。
    /// （ゲーム終了中の得点、ゲーム中の「次のゲーム」、試合終了後の操作など）
    public static func apply(_ event: MatchEvent, to state: MatchState, config: MatchConfig) -> MatchState? {
        var s = state
        switch event {
        case .point(let w):
            guard s.phase == .playing, w == 0 || w == 1 else { return nil }
            s.scores[w] += 1

            // 最終ゲームは、どちらかが5点に達したらエンドを入れ替える
            if isDecidingGame(s.gameIndex, config), !s.switchedEndsMidGame, s.scores[w] == midGameEndChangeAt {
                s.left = 1 - s.left
                s.switchedEndsMidGame = true
            }

            if s.scores[w] >= config.pointsToWin, s.scores[w] - s.scores[1 - w] >= 2 {
                s.finishedGames.append(GameResult(scores: s.scores, winner: w))
                s.server = nil
                if case .bestOf(let n) = config.format, s.gamesWon[w] >= n / 2 + 1 {
                    s.phase = .matchOver(winner: w)
                } else {
                    s.phase = .gameOver(winner: w)
                }
            } else {
                s.server = server(gameIndex: s.gameIndex, scores: s.scores, config: config)
            }

        case .startNextGame:
            guard case .gameOver = s.phase else { return nil }
            s.gameIndex += 1
            s.scores = [0, 0]
            s.phase = .playing
            s.switchedEndsMidGame = false
            // エンドはゲームごとに入れ替える
            s.left = s.gameIndex % 2 == 0 ? config.firstLeft : 1 - config.firstLeft
            s.server = server(gameIndex: s.gameIndex, scores: s.scores, config: config)

        case .resetGame:
            guard s.scores != [0, 0] else { return nil }
            if s.phase != .playing { s.finishedGames.removeLast() }
            s.scores = [0, 0]
            s.phase = .playing
            s.switchedEndsMidGame = false
            s.left = s.gameIndex % 2 == 0 ? config.firstLeft : 1 - config.firstLeft
            s.server = server(gameIndex: s.gameIndex, scores: s.scores, config: config)
        }
        return s
    }

    /// 最終ゲームでエンドを入れ替える点数。
    static let midGameEndChangeAt = 5

    static func isDecidingGame(_ gameIndex: Int, _ config: MatchConfig) -> Bool {
        if case .bestOf(let n) = config.format { return gameIndex == n - 1 }
        return false
    }

    /// サーブは2本ごとに交代。デュース（10-10）以降は1本ごとに交代。
    /// 各ゲームの最初のサーバーは、前のゲームの最初のサーバーと逆になる。
    static func server(gameIndex: Int, scores: [Int], config: MatchConfig) -> Int {
        let first = gameIndex % 2 == 0 ? config.firstServer : 1 - config.firstServer
        let played = scores[0] + scores[1]
        let deucePoints = (config.pointsToWin - 1) * 2
        let changes = played < deucePoints ? played / 2 : deucePoints / 2 + (played - deucePoints)
        return changes % 2 == 0 ? first : 1 - first
    }
}
