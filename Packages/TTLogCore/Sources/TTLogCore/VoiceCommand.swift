import Foundation

/// 音声で受け付ける操作。
public enum VoiceCommand: Hashable, Sendable {
    /// その試合の players[player] に1点。
    case point(player: Int)
    case undo
    /// 「戻す」で取り消した操作をやり直す。
    case redo
    case nextGame
    case toggleServer
    case swapEnds
    /// いまのゲームの得点を 0-0 に戻す。
    case resetGame
}

/// 聞き取った発話（ひらがなの読み）を操作に対応させる。
///
/// 発話全体が語彙と一致したときだけ反応する。会話の中に名前が出てきただけでは反応しない。
/// 1人の選手を複数の言葉で呼べる（画面の左右の言葉と呼び名の両方など）。
/// 言葉には「てん」「ポイント」「くん」などを付けてもよい（「さくらてん」「さくらくんのポイント」「さくら1点」）。
/// 同じ言葉の繰り返し（「ひだりひだり」）は1回分として扱う。
///
/// 名前とスコアの言い方がぶつかるとき：
/// - 名前そのもの（「わん」「いちご」）は名前として扱う。登録した言葉なので優先する
/// - 付け足した形がスコアとしても読めるもの（「わんてん」= 1-10、「ななさん」= 7-3）は名前として登録しない。
///   スコアとして、いまの得点に照らして判断する（6-3 で「ななさん」なら 7-3 になる側に1点）
public struct VoiceCommandMatcher: Sendable {
    /// 取り消し。実際の練習で口から出た言い方を受け付ける。
    public static let undoReadings = [
        "もどして", "もどす", "もどせ", "もどそう", "もどって", "もどる", "もどしといて",
        "もとにもどして", "もとにもどす", "もとにもどせ",
        // 「1つ」「1個」は認識が数字で返す形
        "ひとつもどして", "ひとつもどす", "1つもどして", "1つもどす",
        "いっこもどして", "いっこもどす", "1こもどして", "1こもどす",
        "とりけし", "とりけして", "やりなおし",
    ]
    public static let redoReadings = ["すすめる", "すすめて", "すすめ", "すすむ", "ひとつすすめて", "1つすすめて"]
    public static let nextGameReadings = ["つぎのげーむ"]
    public static let toggleServerReadings = ["さーぶ", "さーぶこうたい", "さーぶちぇんじ", "ちぇんじ"]
    public static let swapEndsReadings = ["いれかえ", "いれかえて", "さゆういれかえ"]
    public static let resetReadings = ["りせっと", "りせっとして"]

    /// 卓球の用語。いまは操作にしないが、聞き取れたことを音声ログに残す（後で使えるように）。
    /// 表示名と、受け付ける読み。選手の呼び名や操作語と同じ読みなら、そちらを優先する。
    public static let terms: [(label: String, readings: [String])] = [
        ("デュース", ["でゅーす", "じゅーす"]),
        ("ネット", ["ねっと"]),
        ("レット", ["れっと"]),
        ("エッジ", ["えっじ"]),
        ("サイド", ["さいど"]),
        ("アウト", ["あうと"]),
        ("タイムアウト", ["たいむあうと", "たいむ"]),
        ("チェンジエンド", ["ちぇんじえんど", "ちぇんじえんず", "ちぇんじこーと"]),
        ("ゲームポイント", ["げーむぽいんと"]),
        ("マッチポイント", ["まっちぽいんと"]),
        ("サービス", ["さーびす"]),
        ("フォルト", ["ふぉると", "さーびすふぉると"]),
        ("ナイス", ["ないす", "ないすぼーる", "ないすさーぶ"]),
        ("ドンマイ", ["どんまい"]),
        ("サー", ["さー", "さあ"]),
        ("よし", ["よし", "よっしゃ"]),
        ("チョレイ", ["ちょれい", "ちょれー"]),
    ]

    /// 認識がよく書き換える言い方（練習の音声ログから）。「みぎ」が「ミリ」になる、など。
    public static let misheard: [String: [String]] = ["みぎ": ["みり"], "ひだり": ["ひだ"]]

    /// 名前の後ろの敬称。
    static let honorifics = ["", "くん", "さん", "ちゃん"]
    /// 敬称の後ろの「点」の言い方。「の」を挟んでもよい。「1点」は認識が数字で返す形。
    static let pointWords = ["", "てん", "ぽいんと", "いってん", "1てん", "1ぽいんと", "のてん", "のぽいんと"]

    /// 名前に付け足して言ってもよい形をすべて返す（名前そのものも含む）。
    public static func pointPhrases(callName: String) -> [String] {
        honorifics.flatMap { h in pointWords.map { callName + h + $0 } }
    }

    private let table: [String: VoiceCommand]
    private let termTable: [String: String]

    /// - Parameter playerCallNames: その試合に出ている選手の呼び名（ひらがな）。並び順が `.point(player:)` の番号になる。
    public init(playerCallNames: [String]) {
        self.init(playerWords: playerCallNames.map { [$0] })
    }

    /// - Parameter playerWords: 選手ごとの呼び方（ひらがな）。外側の並び順が `.point(player:)` の番号になる。
    ///   2人のどちらにも当たる読みは、どちらにも決められないので受け付けない。
    public init(playerWords: [[String]]) {
        var owners: [String: Set<Int>] = [:]
        for (i, words) in playerWords.enumerated() {
            for word in words where !KanaNormalizer.canonical(word).isEmpty {
                for base in [word] + (Self.misheard[KanaNormalizer.canonical(word)] ?? []) {
                    // 長音の畳み方が前後の音で変わるので、付け足した形ごと読みを揃える
                    for phrase in Self.pointPhrases(callName: base) {
                        if phrase != base, Self.isScoreCall(phrase) { continue }
                        owners[KanaNormalizer.canonical(phrase), default: []].insert(i)
                    }
                }
            }
        }
        var t: [String: VoiceCommand] = [:]
        for (key, players) in owners where players.count == 1 {
            t[key] = .point(player: players.first!)
        }
        // 操作語は選手名より優先する（同じ読みの選手がいても操作が効くように）
        for r in Self.undoReadings { t[KanaNormalizer.canonical(r)] = .undo }
        for r in Self.redoReadings { t[KanaNormalizer.canonical(r)] = .redo }
        for r in Self.nextGameReadings { t[KanaNormalizer.canonical(r)] = .nextGame }
        for r in Self.toggleServerReadings { t[KanaNormalizer.canonical(r)] = .toggleServer }
        for r in Self.swapEndsReadings { t[KanaNormalizer.canonical(r)] = .swapEnds }
        for r in Self.resetReadings { t[KanaNormalizer.canonical(r)] = .resetGame }
        table = t
        var terms: [String: String] = [:]
        for (label, readings) in Self.terms {
            for r in readings {
                let key = KanaNormalizer.canonical(r)
                if t[key] == nil, !Self.isScoreCall(key) { terms[key] = label }
            }
        }
        termTable = terms
    }

    public func match(reading: String) -> VoiceCommand? {
        let key = KanaNormalizer.canonical(reading)
        return table[key] ?? Self.repeated(key, in: table)
    }

    /// 得点の言葉（呼び方・呼び名とその付け足し）なら、その選手。繰り返しや操作語は見ない。
    public func pointPlayer(reading: String) -> Int? {
        guard case .point(let p) = table[KanaNormalizer.canonical(reading)] else { return nil }
        return p
    }

    /// 卓球の用語なら表示名を返す（「じゅーす」→「デュース」）。操作にはしない。
    public func term(reading: String) -> String? {
        let key = KanaNormalizer.canonical(reading)
        return termTable[key] ?? Self.repeated(key, in: termTable)
    }

    /// 同じ言葉の繰り返し（「ひだりひだり」）。反響で1回の発話が二重に書き起こされることがあるので、1回分として扱う。
    /// スコアとして読めるもの（「わんわん」= 1-1）はスコアに譲る。
    private static func repeated<Value>(_ key: String, in table: [String: Value]) -> Value? {
        let s = Array(key.unicodeScalars)
        let n = s.count
        guard n >= 2, !isScoreCall(key) else { return nil }
        for len in 1...(n / 2) where n % len == 0 {
            let unit = Array(s[0..<len])
            guard stride(from: len, to: n, by: len).allSatisfy({ Array(s[$0..<($0 + len)]) == unit }) else { continue }
            var view = String.UnicodeScalarView()
            view.append(contentsOf: unit)
            if let c = table[String(view)] { return c }
        }
        return nil
    }

    /// 呼び名とスコアの言い方の重なり（選手登録時の注意用）。
    public struct ScoreOverlap: Hashable, Sendable {
        /// 呼び名そのものがスコアとしても読める（「いちご」= 1-5）。名前として扱う。
        public var nameAsScore: [Int]?
        /// スコアとして読むので、名前としては受け付けない付け足しの形（「わんてん」）。
        public var scorePhrases: [String]

        public var isEmpty: Bool { nameAsScore == nil && scorePhrases.isEmpty }
    }

    public static func scoreOverlap(callName: String) -> ScoreOverlap {
        let pairs = ScoreCallParser.pairs(in: callName)
        let phrases = pointPhrases(callName: callName).filter { $0 != callName && isScoreCall($0) }
        return ScoreOverlap(nameAsScore: pairs.sorted { $0.lexicographicallyPrecedes($1) }.first, scorePhrases: phrases)
    }

    /// 操作語のすべての読み。
    public static var commandReadings: [String] {
        undoReadings + redoReadings + nextGameReadings + toggleServerReadings + swapEndsReadings + resetReadings
    }

    static func isScoreCall(_ reading: String) -> Bool {
        !ScoreCallParser.pairs(in: reading).isEmpty
    }

    /// 音声で使われる語のうち、聞き間違えやすい組み合わせを返す（選手登録時の注意用）。
    /// 同じ試合に出る選手の呼び名どうし、および呼び名と操作語を比べる。
    public static func confusablePairs(callNames: [String]) -> [(String, String)] {
        let words = callNames + commandReadings
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
