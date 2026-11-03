/// 「ワンラブ」「ななきゅう」「7対9」のように、スコアを口で言ったときの読み取り。
///
/// 言う順番は決めない（どちらが先でもよい）。今のスコアから見て筋の通る並びを選ぶ（`ScoreCallResolver`）。

public enum ScoreCallParser {
    /// 発話の読みから、2つの数の組の候補をすべて返す（言った順のまま）。
    /// 区切り方が何通りもある（「じゅういち」= 11 か 10・1 か など）ので、候補は複数になりうる。
    public static func pairs(in reading: String) -> Set<[Int]> {
        let s = Array(normalize(reading).unicodeScalars)
        var results = Set<[Int]>()
        search(s, from: 0, numbers: [], into: &results)
        return results
    }

    private static func search(_ s: [Unicode.Scalar], from i: Int, numbers: [Int], into results: inout Set<[Int]>) {
        if numbers.count > 2 { return }
        if i == s.count {
            if numbers.count == 2 { results.insert(numbers) }
            return
        }
        for sep in separators where matches(s, sep, at: i) {
            search(s, from: i + sep.count, numbers: numbers, into: &results)
        }
        // 数字（1桁か2桁）
        if let d0 = digit(s[i]) {
            search(s, from: i + 1, numbers: numbers + [d0], into: &results)
            if i + 1 < s.count, let d1 = digit(s[i + 1]) {
                search(s, from: i + 2, numbers: numbers + [d0 * 10 + d1], into: &results)
            }
        }
        for (word, value) in words where matches(s, word, at: i) {
            search(s, from: i + word.count, numbers: numbers + [value], into: &results)
        }
    }

    private static func matches(_ s: [Unicode.Scalar], _ w: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + w.count <= s.count else { return false }
        return Array(s[i..<(i + w.count)]) == w
    }

    private static func digit(_ s: Unicode.Scalar) -> Int? {
        switch s.value {
        case 0x30...0x39: return Int(s.value - 0x30)
        case 0xFF10...0xFF19: return Int(s.value - 0xFF10) // 全角数字
        default: return nil
        }
    }

    private static func normalize(_ text: String) -> String {
        KanaNormalizer.canonical(text)
    }

    private static let separators: [[Unicode.Scalar]] = ["たい", "の", "と", "ばーさす"].map {
        Array(KanaNormalizer.canonical($0).unicodeScalars)
    }

    /// 数の言い方（日本語と英語）。照合用の読みに揃えてから使う。
    private static let words: [([Unicode.Scalar], Int)] = {
        var list: [(String, Int)] = [
            ("ぜろ", 0), ("れい", 0), ("らぶ", 0),
            ("いち", 1), ("わん", 1),
            ("に", 2), ("にい", 2), ("つー", 2), ("とぅー", 2),
            ("さん", 3), ("すりー", 3),
            ("よん", 4), ("し", 4), ("ふぉー", 4),
            ("ご", 5), ("ふぁいぶ", 5),
            ("ろく", 6), ("しっくす", 6),
            ("なな", 7), ("しち", 7), ("せぶん", 7),
            ("はち", 8), ("えいと", 8),
            ("きゅう", 9), ("く", 9), ("ないん", 9),
            ("じゅう", 10), ("てん", 10),
            ("いれぶん", 11), ("とぅえるぶ", 12),
            ("にじゅう", 20),
        ]
        let ones = ["いち", "に", "さん", "よん", "ご", "ろく", "なな", "はち", "きゅう"]
        for (k, one) in ones.enumerated() {
            list.append(("じゅう" + one, 11 + k))
        }
        list.append(("じゅうし", 14))
        list.append(("じゅうしち", 17))
        list.append(("じゅうく", 19))
        return list.map { (Array(KanaNormalizer.canonical($0.0).unicodeScalars), $0.1) }
    }()
}

/// 口で言ったスコアを、いまの記録に照らして操作に直す。
public enum ScoreCallResolver {
    public enum Resolution: Hashable, Sendable {
        /// いまのスコアと同じ（何もしない。確認の音だけ）。
        case confirm
        /// player に count 点を足す（入れ忘れを追いかける場合は2点以上）。
        case points(player: Int, count: Int)
        /// 1つ前のスコアを言った（直前の点を取り消す）。
        case undo
    }

    /// 入れ忘れを追いかけるのは何点までか。
    public static let maxCatchUp = 3

    /// - Parameter pairs: 言った順の数の組（`ScoreCallParser.pairs`）。
    /// - Returns: 1つに決まればその操作。決まらない・筋が通らないなら nil。
    public static func resolve(pairs: Set<[Int]>, log: SessionLog) -> Resolution? {
        let state = log.state
        let current = state.scores
        let previous = previousScores(log)

        // 言った2つの数を、どちらの選手に当てるか。両方の向きを試す
        struct Candidate: Hashable {
            let resolution: Resolution
            /// サーブの人の点を先に言った向きか（同点のときの決め手）。
            let serverFirst: Bool
        }
        var candidates = Set<Candidate>()
        for pair in pairs where pair.count == 2 {
            for firstPlayer in [0, 1] {
                var target = [0, 0]
                target[firstPlayer] = pair[0]
                target[1 - firstPlayer] = pair[1]
                guard let r = resolution(target: target, current: current, previous: previous, log: log) else { continue }
                candidates.insert(Candidate(resolution: r, serverFirst: state.server == firstPlayer))
            }
        }

        let distinct = Set(candidates.map(\.resolution))
        if distinct.count == 1 { return distinct.first }
        if distinct.isEmpty { return nil }
        // 同点からの1点は、順番だけではどちらの点か決まらない。公式のコールに合わせて「サーブの人が先」とみなす
        let serverFirst = Set(candidates.filter(\.serverFirst).map(\.resolution))
        return serverFirst.count == 1 ? serverFirst.first : nil
    }

    private static func resolution(target: [Int], current: [Int], previous: [Int]?, log: SessionLog) -> Resolution? {
        if target == current { return .confirm }
        if let previous, target == previous { return .undo }
        guard log.state.phase == .playing else { return nil }
        // 片方だけが進んでいる形だけ受け付ける（両方進んでいると、どの順で入ったかわからない）
        for p in [0, 1] where target[1 - p] == current[1 - p] {
            let n = target[p] - current[p]
            guard (1...maxCatchUp).contains(n) else { continue }
            // 途中でゲームが終わってしまう足し方は筋が通らない
            var trial = log
            var ok = true
            for k in 0..<n {
                guard trial.append(.point(winner: p), at: log.startedAt, source: .voice) else { ok = false; break }
                if k < n - 1, trial.state.phase != .playing { ok = false; break }
            }
            if ok { return .points(player: p, count: n) }
        }
        return nil
    }

    /// 直前の操作が今のゲームの得点なら、それを取り消したときのスコア。
    private static func previousScores(_ log: SessionLog) -> [Int]? {
        guard case .point = log.events.last?.event else { return nil }
        var trial = log
        trial.undo()
        guard trial.state.gameIndex == log.state.gameIndex else { return nil }
        return trial.state.scores
    }
}
