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
        guard !events.isEmpty else { return false }
        events.removeLast()
        return true
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
                games[games.count - 1].points.append(.init(winner: w, at: e.at, scores: next.scores))
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

/// 時刻を端末間でやりとりするときの表し方（1970年からのミリ秒）。Android でも扱いやすいように。
public extension Date {
    var epochMilliseconds: Double { timeIntervalSince1970 * 1000 }
    init(epochMilliseconds ms: Double) { self.init(timeIntervalSince1970: ms / 1000) }
}
