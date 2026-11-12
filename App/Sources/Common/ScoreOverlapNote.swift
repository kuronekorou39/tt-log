import TTLogCore

/// 呼び名がスコアの言い方と重なるときの注意書き（選手登録・設定の画面に出す）。
enum ScoreOverlapNote {
    static func text(callName: String) -> String? {
        let o = VoiceCommandMatcher.scoreOverlap(callName: callName)
        guard !o.isEmpty else { return nil }
        var lines: [String] = []
        if let pair = o.nameAsScore {
            lines.append("「\(callName)」は \(pair[0])-\(pair[1]) とも読めます（名前を優先）")
        }
        if !o.scorePhrases.isEmpty {
            let examples = o.scorePhrases.prefix(3).map { "「\($0)」" }.joined()
            lines.append("\(examples)はスコアとして読みます")
        }
        return lines.joined(separator: "\n")
    }
}
