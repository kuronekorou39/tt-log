import SwiftUI

/// 声で選手を呼び分ける言葉の組み。スコアボードの各パネルの上に、その側の言葉を帯で出す。
///
/// 色の組は選手についてくる（紅白戦のゼッケンのように、エンドが変わっても同じ色）。
/// 左右と自由入力は画面の位置につくので、エンドが変わると呼び方も入れ替わる。
enum CallStyle: String, CaseIterable, Identifiable {
    case side
    case redWhite
    case blackWhite
    case custom

    static let storageKey = "voice.callStyle"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .side: return "左右（ひだり／みぎ）"
        case .redWhite: return "赤と白（あか／しろ）"
        case .blackWhite: return "黒と白（くろ／しろ）"
        case .custom: return "自由に決める"
        }
    }

    var detail: String {
        switch self {
        case .side, .custom:
            return "画面の左右で呼ぶ"
        case .redWhite, .blackWhite:
            return "A＝\(colors[0].word)　B＝\(colors[1].word)"
        }
    }

    /// 色が選手についてくるか（左右の言葉は画面の位置につく）。
    var followsPlayer: Bool { self == .redWhite || self == .blackWhite }

    /// 選手 A, B の順の色。色の組でなければ空。
    private var colors: [CallTag] {
        switch self {
        case .redWhite: return [.red, .white]
        case .blackWhite: return [.black, .white]
        case .side, .custom: return []
        }
    }

    /// 選手ごとの呼び方と帯の見た目。
    /// - Parameters:
    ///   - left: 画面の左にいる選手。
    ///   - customWords: 自由入力の言葉（左、右の順）。
    func tag(for player: Int, left: Int, customWords: (String, String)) -> CallTag {
        if followsPlayer { return colors[player] }
        let isLeft = player == left
        let word: String
        switch self {
        case .custom: word = isLeft ? customWords.0 : customWords.1
        default: word = isLeft ? "ひだり" : "みぎ"
        }
        return CallTag(word: word, fill: nil, text: nil, arrow: isLeft ? .leading : .trailing)
    }
}

/// パネルの上の帯に出す、呼び方の札。
struct CallTag: Equatable {
    let word: String
    /// 帯の色。nil なら目立たない色（左右の言葉）。
    let fill: Color?
    let text: Color?
    /// 左右の言葉のときに添える矢印の向き。
    var arrow: HorizontalEdge?

    static let red = CallTag(word: "あか", fill: Color(red: 0.84, green: 0.13, blue: 0.17), text: .white)
    static let white = CallTag(word: "しろ", fill: Color(white: 0.97), text: Color(white: 0.1))
    static let black = CallTag(word: "くろ", fill: Color(white: 0.06), text: .white)
}
