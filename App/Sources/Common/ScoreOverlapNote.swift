import TTLogCore

/// 呼び名がスコアの言い方と重なるときの注意書き（選手登録・設定の画面に出す）。
enum ScoreOverlapNote {
    static func text(callName: String) -> String? {
        let o = VoiceCommandMatcher.scoreOverlap(callName: callName)
        guard !o.isEmpty else { return nil }
        var lines: [String] = []
        if let pair = o.nameAsScore {
            lines.append("「\(callName)」は \(pair[0])-\(pair[1]) のスコアとも読めます。名前を優先するので、このスコアは別の言い方で言ってください。")
        }
        if !o.scorePhrases.isEmpty {
            let examples = o.scorePhrases.prefix(3).map { "「\($0)」" }.joined()
            lines.append("\(examples)などはスコアとして読みます（いまの得点に合えばその人に1点）。名前だけで呼べば確実です。")
        }
        return lines.joined(separator: "\n")
    }
}
