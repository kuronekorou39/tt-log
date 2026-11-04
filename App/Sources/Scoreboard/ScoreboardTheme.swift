import SwiftUI

/// 表示だけの端末内設定。試合の記録やカメラへの配信には含めない。
enum ScoreboardTheme: String, CaseIterable, Identifiable {
    case simple
    case flip
    case arena
    case focus

    static let storageKey = "scoreboard.theme"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple: return "シンプル"
        case .flip: return "フリップ"
        case .arena: return "アリーナ"
        case .focus: return "フォーカス"
        }
    }

    var detail: String {
        switch self {
        case .simple: return "使い慣れた、すっきりした表示。"
        case .flip: return "めくり式の得点板。黒いカードに黄色の数字。"
        case .arena: return "電光掲示板の数字と、選手ごとのアクセント。"
        case .focus: return "明るい背景と大きな数字。離れていても、ひと目で。"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .simple: return nil
        case .flip, .arena: return .dark
        case .focus: return .light
        }
    }

    var background: Color {
        switch self {
        case .simple: return Color(uiColor: .systemBackground)
        case .flip: return Color(red: 0.075, green: 0.08, blue: 0.09)
        case .arena: return Color(red: 0.025, green: 0.045, blue: 0.065)
        case .focus: return Color(red: 0.95, green: 0.95, blue: 0.92)
        }
    }

    var foreground: Color {
        switch self {
        case .simple: return .primary
        case .flip, .arena: return .white
        case .focus: return Color(red: 0.07, green: 0.13, blue: 0.19)
        }
    }

    /// 遠くから判別するため、不透明な帯と太枠に同じ色を使う。
    func serveHighlight(for player: Int) -> Color {
        switch self {
        case .simple, .flip: return Color(red: 1, green: 0.85, blue: 0.22)
        case .arena: return accent(for: player)
        case .focus: return foreground
        }
    }

    var serveForeground: Color {
        self == .focus ? .white : Color(red: 0.06, green: 0.09, blue: 0.12)
    }

    /// 画面の左右ではなく、試合中の選手番号に色を固定する。
    func accent(for player: Int) -> Color {
        switch self {
        case .simple: return .orange
        case .flip: return Color(red: 1, green: 0.85, blue: 0.22)
        case .arena:
            return player == 0
                ? Color(red: 0.40, green: 0.94, blue: 0.86)
                : Color(red: 1, green: 0.72, blue: 0.38)
        case .focus:
            return player == 0
                ? Color(red: 0.76, green: 0.88, blue: 0.98)
                : Color(red: 0.98, green: 0.83, blue: 0.59)
        }
    }
}
