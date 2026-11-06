import Foundation

/// 入力の出どころ。
public enum InputSource: String, Codable, Hashable, Sendable {
    case tap, voice
}

/// 時刻付きの操作。
public struct TimedEvent: Codable, Hashable, Sendable {
    public var event: MatchEvent
    public var at: Date
    public var source: InputSource

    public init(event: MatchEvent, at: Date, source: InputSource) {
        self.event = event
        self.at = at
        self.source = source
    }
}

/// 1ゲームの経過。
public struct GameTimeline: Hashable, Sendable {
    public struct Point: Hashable, Sendable {
        public let winner: Int
        public let at: Date
        /// この点が入った後の得点。
        public let scores: [Int]
        /// この点のラリーでサーブした選手。
        public let server: Int
        public let source: InputSource
    }

    public let index: Int
    public let startedAt: Date
    /// 決着した時刻。続いているゲームは nil。
    public internal(set) var endedAt: Date?
    public internal(set) var points: [Point] = []
    public internal(set) var winner: Int?
}

/// 1回の試合（連続形式なら1日の練習）の記録。状態は保存せず、操作の列から導く。
public struct SessionLog: Codable, Hashable, Sendable {
    public var config: MatchConfig
    public var startedAt: Date
    public var events: [TimedEvent]

    public init(config: MatchConfig, startedAt: Date, events: [TimedEvent] = []) {
        self.config = config
        self.startedAt = startedAt
        self.events = events
    }

    public var state: MatchState {
        RuleEngine.reduce(config, events.map(\.event))
    }

    /// 操作を追加する。いまの状態で受け付けない操作なら追加せず false を返す。
    @discardableResult
    public mutating func append(_ event: MatchEvent, at: Date, source: InputSource) -> Bool {
        guard RuleEngine.apply(event, to: state, config: config) != nil else { return false }
        events.append(TimedEvent(event: event, at: at, source: source))
        return true
    }

    /// 最後の操作を取り消す。取り消すものがなければ false。
    @discardableResult
    public mutating func undo() -> Bool {
        popLast() != nil
    }

    /// 最後の操作を取り消して返す（やり直し用に取っておける）。
    public mutating func popLast() -> TimedEvent? {
        events.popLast()
    }

    /// 取り消した操作をやり直す。いまの状態で受け付けない操作なら false。
    @discardableResult
    public mutating func redo(_ event: TimedEvent) -> Bool {
        guard RuleEngine.apply(event.event, to: state, config: config) != nil else { return false }
        events.append(event)
        return true
    }

    /// いまのゲームのサーバーを入れ替える（最初のサーバーの設定を逆にする。以降のゲームも筋が通る）。
    public mutating func toggleServer() {
        config.firstServer = 1 - config.firstServer
    }

    /// いまの左右を入れ替える（最初のエンドの設定を逆にする）。
    public mutating func swapEnds() {
        config.firstLeft = 1 - config.firstLeft
    }

    /// ゲームごとの経過（開始・終了時刻と各得点の時刻）。
    /// 第1ゲームは記録の開始時刻、以降は「次のゲーム」の時刻を開始とする。
    public func games() -> [GameTimeline] {
        var state = RuleEngine.reduce(config, [])
        var games = [GameTimeline(index: 0, startedAt: startedAt)]
        for e in events {
            guard let next = RuleEngine.apply(e.event, to: state, config: config) else { continue }
            switch e.event {
            case .point(let w):
                // ゲーム中は必ずサーバーがいる（ゲーム終了中の得点は apply が受け付けない）
                let server = state.server ?? w
                games[games.count - 1].points.append(.init(winner: w, at: e.at, scores: next.scores,
                                                           server: server, source: e.source))
                if next.phase != .playing {
                    games[games.count - 1].endedAt = e.at
                    games[games.count - 1].winner = w
                }
            case .startNextGame:
                games.append(GameTimeline(index: next.gameIndex, startedAt: e.at))
            }
            state = next
        }
        return games
    }
}

/// 2人の得点の内訳（結果の画面と共有に使う）。
public struct PlayerStats: Hashable, Sendable {
    public var points = 0
    /// 自分がサーブしたラリーで取った点。
    public var servePointsWon = 0
    /// 自分がサーブしたラリーの数。
    public var servePointsPlayed = 0
    /// 相手がサーブしたラリーで取った点。
    public var receivePointsWon = 0
    public var receivePointsPlayed = 0
    /// 続けて取った点の最大。
    public var longestRun = 0

    public init() {}
}

public extension Array where Element == GameTimeline {
    /// 選手の番号順の内訳。
    func playerStats() -> [PlayerStats] {
        var stats = [PlayerStats(), PlayerStats()]
        for game in self {
            var runner = -1
            var run = 0
            for p in game.points {
                let loser = 1 - p.winner
                stats[p.winner].points += 1
                if p.server == p.winner {
                    stats[p.winner].servePointsWon += 1
                    stats[p.winner].servePointsPlayed += 1
                    stats[loser].receivePointsPlayed += 1
                } else {
                    stats[p.winner].receivePointsWon += 1
                    stats[p.winner].receivePointsPlayed += 1
                    stats[loser].servePointsPlayed += 1
                }
                run = p.winner == runner ? run + 1 : 1
                runner = p.winner
                stats[p.winner].longestRun = Swift.max(stats[p.winner].longestRun, run)
            }
        }
        return stats
    }
}

/// 時刻を端末間でやりとりするときの表し方（1970年からのミリ秒）。Android でも扱いやすいように。
public extension Date {
    var epochMilliseconds: Double { timeIntervalSince1970 * 1000 }
    init(epochMilliseconds ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
