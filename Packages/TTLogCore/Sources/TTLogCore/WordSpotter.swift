/// 話している途中の文字から、得点の言葉（「ひだり」「みぎ」、呼び名）を見つける。
///
/// 言い終わるのを待たずに反映するため（2026-11-12 の練習で、反映が遅いことと、
/// 前後に会話や笑い声があると発話全体が一致せずに取りこぼすことが分かった）。
///
/// 文は単語に区切ってから見る（「君嫌い」の中の「みぎ」は拾わない）。
/// 見つけた言葉のすぐ後ろが
/// - なにもない → `pending`（少し待って続きが来なければ受け付ける）
/// - 笑い声・かけ声・ほかの言葉 → `accepted`
/// - それ以外（「右に行く」の「に」、「右奥」の「奥」） → `rejected`
public enum WordSpotter {
    public enum Status: Hashable, Sendable {
        case accepted
        case pending
        case rejected
    }

    public struct Hit: Hashable, Sendable {
        public let player: Int
        /// 言葉が始まる単語の位置。
        public let tokenIndex: Int
        public let status: Status
    }

    /// 何語までつなげて1つの言葉とみなすか（「ひだり」「てん」→「ひだりてん」）。
    static let maxSpan = 4

    /// 言葉の後ろに続いても、別の言葉とみなすかけ声（笑い声は形で見る）。
    static let fillers: Set<String> = [
        "はい", "うん", "え", "あ", "お", "おっけ", "やった", "くそ", "いえい", "よっしゃ", "ほら", "まじ", "やば", "やばい",
    ].reduce(into: []) { $0.insert(KanaNormalizer.canonical($1)) }

    /// 笑い声や「あっ」のような声だけでできた単語。
    private static let laughSounds = Set("あいうえおぁぃぅぇぉはひふへほっんわー".unicodeScalars)

    /// - Parameter tokens: 単語ごとの読み（ひらがな）。
    public static func hits(tokens: [String], matcher: VoiceCommandMatcher) -> [Hit] {
        let words = tokens.map(KanaNormalizer.canonical).filter { !$0.isEmpty }
        var result: [Hit] = []
        var i = 0
        while i < words.count {
            var found: (player: Int, length: Int)?
            for length in stride(from: min(maxSpan, words.count - i), through: 1, by: -1) {
                if let p = matcher.pointPlayer(reading: words[i..<(i + length)].joined()) {
                    found = (p, length)
                    break
                }
            }
            guard let found else {
                i += 1
                continue
            }
            let next = i + found.length
            let status: Status
            if next == words.count {
                status = .pending
            } else if isBreak(words[next], matcher: matcher) {
                status = .accepted
            } else {
                status = .rejected
            }
            result.append(Hit(player: found.player, tokenIndex: i, status: status))
            i = next
        }
        return result
    }

    /// 言葉の後ろに来ても「続き」ではないもの。
    static func isBreak(_ word: String, matcher: VoiceCommandMatcher) -> Bool {
        if fillers.contains(word) { return true }
        if word.unicodeScalars.allSatisfy(laughSounds.contains) { return true }
        if matcher.match(reading: word) != nil || matcher.term(reading: word) != nil { return true }
        return false
    }
}
