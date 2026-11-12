import Foundation

// スコアボード端末（iPad）とカメラ端末（iPhone / 将来 Android）のあいだのメッセージ。
// 形式は docs/protocol.md に書く。変えたら両方を直すこと。
//
// - 通信は WebSocket のテキストメッセージ（JSON 1つ = 1メッセージ）
// - 時刻はすべて 1970年からのミリ秒（送った端末の時計）

public enum PeerProtocol {
    public static let version = 1
    /// Bonjour のサービス名。
    public static let serviceType = "_ttlog._tcp"
    /// 待ち受けポート（Bonjour で見つからないときに IP アドレスだけで手入力できるよう固定する）。
    public static let port: UInt16 = 52740
}

public struct PeerHello: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case scoreboard, camera }
    public var role: Role
    public var deviceName: String
    public var protocolVersion: Int

    public init(role: Role, deviceName: String, protocolVersion: Int = PeerProtocol.version) {
        self.role = role
        self.deviceName = deviceName
        self.protocolVersion = protocolVersion
    }
}

/// スコアボードの今の状態。変化するたびに丸ごと送る（受け手は最新のものだけ見ればよい）。
/// 途中でつなぎ直しても、次に届いた1通で追いつける。
public struct ScoreboardSnapshot: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// 試合をしていない（記録を終えた、またはまだ始めていない）。
        case idle
        case playing
        case gameOver
        case matchOver
    }

    public struct Point: Codable, Hashable, Sendable {
        public var winner: Int
        public var at: Double
        public var scores: [Int]

        public init(winner: Int, at: Double, scores: [Int]) {
            self.winner = winner
            self.at = at
            self.scores = scores
        }
    }

    /// 記録の ID。idle のときは nil。
    public var sessionId: String?
    public var sessionStartedAt: Double?
    public var playerNames: [String]
    public var gameIndex: Int
    public var phase: Phase
    public var scores: [Int]
    /// 画面の左側にいる選手の番号。
    public var left: Int
    public var server: Int?
    public var gameStartedAt: Double?
    public var gameEndedAt: Double?
    /// いまのゲームの得点の経過。
    public var points: [Point]
    public var sentAt: Double

    public init(
        sessionId: String?, sessionStartedAt: Double?, playerNames: [String], gameIndex: Int,
        phase: Phase, scores: [Int], left: Int, server: Int?, gameStartedAt: Double?,
        gameEndedAt: Double?, points: [Point], sentAt: Double
    ) {
        self.sessionId = sessionId
        self.sessionStartedAt = sessionStartedAt
        self.playerNames = playerNames
        self.gameIndex = gameIndex
        self.phase = phase
        self.scores = scores
        self.left = left
        self.server = server
        self.gameStartedAt = gameStartedAt
        self.gameEndedAt = gameEndedAt
        self.points = points
        self.sentAt = sentAt
    }

    public static func idle(sentAt: Double) -> ScoreboardSnapshot {
        ScoreboardSnapshot(
            sessionId: nil, sessionStartedAt: nil, playerNames: [], gameIndex: 0, phase: .idle,
            scores: [0, 0], left: 0, server: nil, gameStartedAt: nil, gameEndedAt: nil, points: [], sentAt: sentAt
        )
    }

    /// カメラが録画しているべきか（試合中で、ゲームが続いている）。
    public var shouldRecord: Bool {
        sessionId != nil && phase == .playing
    }
}

public extension SessionLog {
    func snapshot(sessionId: String, playerNames: [String], now: Date) -> ScoreboardSnapshot {
        let s = state
        let game = games().last
        let phase: ScoreboardSnapshot.Phase
        switch s.phase {
        case .playing: phase = .playing
        case .gameOver: phase = .gameOver
        case .matchOver: phase = .matchOver
        }
        return ScoreboardSnapshot(
            sessionId: sessionId,
            sessionStartedAt: startedAt.epochMilliseconds,
            playerNames: playerNames,
            gameIndex: s.gameIndex,
            phase: phase,
            scores: s.scores,
            left: s.left,
            server: s.server,
            gameStartedAt: game?.startedAt.epochMilliseconds,
            gameEndedAt: game?.endedAt?.epochMilliseconds,
            points: (game?.points ?? []).map { .init(winner: $0.winner, at: $0.at.epochMilliseconds, scores: $0.scores) },
            sentAt: now.epochMilliseconds
        )
    }
}

/// カメラの録画の状態。カメラ → スコアボード。数秒ごとと、変わったときに送る。
/// スコアボードは、これが届かなくなったら「カメラの様子が分からない」と出す。
public struct CameraStatus: Codable, Hashable, Sendable {
    /// ファイルへの書き込みが進んでいる（録画を頼んだだけでは true にしない）。
    public var recording: Bool
    /// いまの録画の長さ（秒）。録画していなければ nil。
    public var clipSeconds: Double?
    /// 録画できていない理由など、直近の問題。なければ nil。
    public var problem: String?
    /// 電池の残り（%）。わからないときは nil。
    public var battery: Int?
    /// 温度の段階。0 正常 / 1 やや高い / 2 高い / 3 危険。
    public var thermal: Int
    public var sentAt: Double

    public init(recording: Bool, clipSeconds: Double?, problem: String?, battery: Int?, thermal: Int, sentAt: Double) {
        self.recording = recording
        self.clipSeconds = clipSeconds
        self.problem = problem
        self.battery = battery
        self.thermal = thermal
        self.sentAt = sentAt
    }
}

public enum PeerMessage: Hashable, Sendable {
    case hello(PeerHello)
    case state(ScoreboardSnapshot)
    case cameraStatus(CameraStatus)
    /// 時計のずれを測るための往復。カメラ → スコアボード。
    case ping(sentAt: Double)
    /// スコアボード → カメラ。受け取った ping の sentAt と、スコアボードの時計で受け取った時刻。
    case pong(pingSentAt: Double, receivedAt: Double)
}

extension PeerMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, hello, state, cameraStatus, sentAt, pingSentAt, receivedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "hello": self = .hello(try c.decode(PeerHello.self, forKey: .hello))
        case "state": self = .state(try c.decode(ScoreboardSnapshot.self, forKey: .state))
        case "cameraStatus": self = .cameraStatus(try c.decode(CameraStatus.self, forKey: .cameraStatus))
        case "ping": self = .ping(sentAt: try c.decode(Double.self, forKey: .sentAt))
        case "pong":
            self = .pong(
                pingSentAt: try c.decode(Double.self, forKey: .pingSentAt),
                receivedAt: try c.decode(Double.self, forKey: .receivedAt)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let h):
            try c.encode("hello", forKey: .type)
            try c.encode(h, forKey: .hello)
        case .state(let s):
            try c.encode("state", forKey: .type)
            try c.encode(s, forKey: .state)
        case .cameraStatus(let s):
            try c.encode("cameraStatus", forKey: .type)
            try c.encode(s, forKey: .cameraStatus)
        case .ping(let t):
            try c.encode("ping", forKey: .type)
            try c.encode(t, forKey: .sentAt)
        case .pong(let t0, let t1):
            try c.encode("pong", forKey: .type)
            try c.encode(t0, forKey: .pingSentAt)
            try c.encode(t1, forKey: .receivedAt)
        }
    }
}

public enum PeerCodec {
    public static func encode(_ message: PeerMessage) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return try e.encode(message)
    }

    public static func decode(_ data: Data) throws -> PeerMessage {
        try JSONDecoder().decode(PeerMessage.self, from: data)
    }
}

/// 端末間の時計のずれを、ping / pong の往復から推定する（簡易 NTP）。
/// 往復時間が短い測定ほど正確なので、直近の測定のうち往復が最短のものを使う。
public struct ClockSync: Sendable {
    private struct Sample: Sendable {
        let roundTrip: Double
        let offset: Double
    }

    private var samples: [Sample] = []
    private let window: Int

    public init(window: Int = 20) {
        self.window = window
    }

    /// - Parameters:
    ///   - sentAt: こちらが ping を送った時刻（こちらの時計）
    ///   - remoteAt: 相手が受け取った時刻（相手の時計）
    ///   - receivedAt: こちらが pong を受け取った時刻（こちらの時計）
    public mutating func add(sentAt: Double, remoteAt: Double, receivedAt: Double) {
        let rtt = receivedAt - sentAt
        guard rtt >= 0 else { return }
        samples.append(Sample(roundTrip: rtt, offset: remoteAt - (sentAt + receivedAt) / 2))
        if samples.count > window { samples.removeFirst(samples.count - window) }
    }

    /// 相手の時計 − こちらの時計（ミリ秒）。まだ測っていなければ nil。
    public var offset: Double? {
        samples.min { $0.roundTrip < $1.roundTrip }?.offset
    }

    /// 相手の時計の時刻を、こちらの時計に直す。
    public func toLocal(_ remote: Double) -> Double {
        remote - (offset ?? 0)
    }
}
