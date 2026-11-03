import Foundation

/// 漢字かな交じりの文をひらがなの読みにする。
///
/// 音声認識は「戻して」「次のゲーム」のように漢字やカタカナで返すことがあるので、
/// 呼び名と照合する前に読みに揃える。
enum ReadingConverter {
    static func hiragana(_ text: String) -> String {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, cfText, range,
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja_JP") as CFLocale
        )
        let nsText = text as NSString
        var out = ""
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while !tokenType.isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let token = nsText.substring(with: NSRange(location: r.location, length: r.length))
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String,
               let kana = latin.applyingTransform(.latinToHiragana, reverse: false) {
                out += kana
            } else {
                out += token
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return out
    }
}
