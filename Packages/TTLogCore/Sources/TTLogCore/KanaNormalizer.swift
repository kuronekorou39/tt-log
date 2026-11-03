/// 音声認識の結果と呼び名を照合するために、読みを揃える。
///
/// 漢字→ひらがなの変換は Apple の API が要るのでアプリ側で行い、
/// ここではひらがな/カタカナになった文字列だけを扱う。
public enum KanaNormalizer {
    /// 照合用の読みを返す。
    /// - カタカナはひらがなにする
    /// - 空白・句読点・記号は捨てる
    /// - 長音は畳む（「こう」「こお」「こー」はどれも「こ」になる）
    public static func canonical(_ text: String) -> String {
        var out: [Unicode.Scalar] = []
        for raw in text.unicodeScalars {
            if isIgnorable(raw) { continue }
            let s = toHiragana(raw)
            if s == "ー" { continue }
            if let prev = out.last, let prevVowel = vowel(of: prev),
               let v = pureVowel[s], lengthens(v, after: prevVowel) {
                continue
            }
            out.append(s)
        }
        var result = String.UnicodeScalarView()
        result.append(contentsOf: out)
        return String(result)
    }

    private static func isIgnorable(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .spaceSeparator, .lineSeparator, .paragraphSeparator, .control,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    /// カタカナ（ァ〜ヶ）をひらがなにずらす。
    private static func toHiragana(_ s: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x30A1...0x30F6).contains(s.value),
              let h = Unicode.Scalar(s.value - 0x60) else { return s }
        return h
    }

    /// 直前の音を伸ばしているだけの母音か（「お」の後の「う」、「え」の後の「い」も含む）。
    private static func lengthens(_ v: Character, after prev: Character) -> Bool {
        v == prev || (prev == "o" && v == "u") || (prev == "e" && v == "i")
    }

    private static let pureVowel: [Unicode.Scalar: Character] = [
        "あ": "a", "い": "i", "う": "u", "え": "e", "お": "o",
    ]

    private static func vowel(of s: Unicode.Scalar) -> Character? { vowelTable[s] }

    private static let vowelTable: [Unicode.Scalar: Character] = {
        let rows: [(Character, String)] = [
            ("a", "あかさたなはまやらわがざだばぱぁゃ"),
            ("i", "いきしちにひみりぎじぢびぴぃ"),
            ("u", "うくすつぬふむゆるぐずづぶぷぅゅゔ"),
            ("e", "えけせてねへめれげぜでべぺぇ"),
            ("o", "おこそとのほもよろをごぞどぼぽぉょ"),
        ]
        var table: [Unicode.Scalar: Character] = [:]
        for (v, kana) in rows {
            for s in kana.unicodeScalars { table[s] = v }
        }
        return table
    }()
}
