import Foundation

/// 音声で受け付ける操作。
public enum VoiceCommand: Hashable, Sendable {
    /// その試合の players[player] に1点。
    case point(player: Int)
    case undo
    case nextGame
}

/// 聞き取った発話（ひらがなの読み）を操作に対応させる。
///
/// 発話全体が語彙と一致したときだけ反応する。会話の中に名前が出てきただけでは反応しない。
/// 名前には「てん」「ポイント」「くん」などを付けてもよい（「さくらてん」「さくらくんのポイント」）。
public struct VoiceCommandMatcher: Sendable {
    public static let undoReadings = ["もどして"]
    public static let nextGameReadings = ["つぎのげーむ"]

    /// 名前の後ろの敬称。
    static let honorifics = ["", "くん", "さん", "ちゃん"]
    /// 敬称の後ろの「点」の言い方。「の」を挟んでもよい。
    static let pointWords = ["", "てん", "ぽいんと", "いってん", "のてん", "のぽいんと"]

    /// 名前に付け足して言ってもよい形をすべて返す（名前そのものも含む）。
    public static func pointPhrases(callName: String) -> [String] {
        honorifics.flatMap { h in pointWords.map { callName + h + $0 } }
    }

    private let table: [String: VoiceCommand]

    /// - Parameter playerCallNames: その試合に出ている選手の呼び名（ひらがな）。並び順が `.point(player:)` の番号になる。
    public init(playerCallNames: [String]) {
        var t: [String: VoiceCommand] = [:]
        for (i, name) in playerCallNames.enumerated() where !KanaNormalizer.canonical(name).isEmpty {
            // 長音の畳み方が前後の音で変わるので、付け足した形ごと読みを揃える
            for phrase in Self.pointPhrases(callName: name) {
                let key = KanaNormalizer.canonical(phrase)
                if t[key] == nil { t[key] = .point(player: i) }
            }
        }
        // 操作語は選手名より優先する（同じ読みの選手がいても操作が効くように）
        for r in Self.undoReadings { t[KanaNormalizer.canonical(r)] = .undo }
        for r in Self.nextGameReadings { t[KanaNormalizer.canonical(r)] = .nextGame }
        table = t
    }

    public func match(reading: String) -> VoiceCommand? {
        table[KanaNormalizer.canonical(reading)]
    }

    /// 音声で使われる語のうち、聞き間違えやすい組み合わせを返す（選手登録時の注意用）。
    /// 同じ試合に出る選手の呼び名どうし、および呼び名と操作語を比べる。
    public static func confusablePairs(callNames: [String]) -> [(String, String)] {
        let words = callNames + undoReadings + nextGameReadings
        var pairs: [(String, String)] = []
        for i in words.indices {
            for j in words.indices where j > i && i < callNames.count {
                if areConfusable(words[i], words[j]) { pairs.append((words[i], words[j])) }
            }
        }
        return pairs
    }

    static func areConfusable(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(KanaNormalizer.canonical(lhs).unicodeScalars)
        let b = Array(KanaNormalizer.canonical(rhs).unicodeScalars)
        if a == b { return true }
        // 1文字どうしは必ず1文字違いになるので、どちらかが2文字以上のときだけ見る
        return max(a.count, b.count) >= 2 && editDistance(a, b) <= 1
    }

    private static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            prev = cur
        }
        return prev[b.count]
    }
}

/// 同じ操作が短い間に二重に入るのを防ぐ。
public struct CommandGate: Sendable {
    /// 同じ操作を受け付けない時間（秒）。
    public var deadTime: TimeInterval
    private var last: (command: VoiceCommand, at: Date)?

    public init(deadTime: TimeInterval) {
        self.deadTime = deadTime
    }

    /// 受け付けるなら true を返し、時刻を記録する。
    public mutating func accept(_ command: VoiceCommand, at now: Date) -> Bool {
        if let last, last.command == command, now.timeIntervalSince(last.at) < deadTime {
            return false
        }
        last = (command, now)
        return true
    }
}
