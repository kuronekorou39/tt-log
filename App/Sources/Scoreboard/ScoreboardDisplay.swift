import SwiftUI
import TTLogCore

/// 実画面とデザイン選択の見本で共用する表示。得点操作は呼び出し元に渡す。
struct ScoreboardDisplay: View {
    let theme: ScoreboardTheme
    let state: MatchState
    let playerNames: [String]
    var onPoint: (Int) -> Void = { _ in }

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = theme == .simple ? 0 : min(20, proxy.size.width * 0.018)
            HStack(spacing: theme == .simple ? 0 : inset) {
                panel(player: state.left)
                if theme == .simple { Divider() }
                panel(player: 1 - state.left)
            }
            .padding(inset)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.background)
    }

    private func panel(player: Int) -> some View {
        let name = playerNames.indices.contains(player) ? playerNames[player] : (player == 0 ? "A" : "B")
        return Button {
            onPoint(player)
        } label: {
            ScoreboardPlayerPanel(theme: theme, player: player, name: name,
                                  score: state.scores[player], games: state.gamesWon[player],
                                  isServing: state.server == player)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScoreboardPointButtonStyle())
        .disabled(state.phase != .playing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(state.server == player ? "サーブ、" : "")\(state.scores[player])点、獲得ゲーム\(state.gamesWon[player])")
        .accessibilityHint(state.phase == .playing ? "ダブルタップで1点追加" : "ゲーム終了")
        .accessibilityIdentifier("scoreboard.player.\(player)")
    }
}

private struct ScoreboardPointButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.78 : 1)
    }
}

private struct ScoreboardPlayerPanel: View {
    let theme: ScoreboardTheme
    let player: Int
    let name: String
    let score: Int
    let games: Int
    let isServing: Bool

    private var accent: Color { theme.accent(for: player) }
    private var serviceColor: Color { theme.serveHighlight(for: player) }

    var body: some View {
        GeometryReader { proxy in
            let inset = max(6, min(26, proxy.size.width * 0.055))
            let nameSize = max(12, min(40, min(proxy.size.width * 0.09, proxy.size.height * 0.12)))
            let detailSize = max(10, min(20, proxy.size.height * 0.055))
            let serveHeight = min(112, max(36, proxy.size.height * 0.19))
            let borderWidth = max(3, min(9, proxy.size.width * 0.017))
            let cornerRadius: CGFloat = theme == .simple ? 0 : 16
            VStack(spacing: 0) {
                VStack(spacing: max(6, min(18, proxy.size.height * 0.035))) {
                    HStack(spacing: 8) {
                        if theme == .arena {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(accent)
                                .frame(width: 4, height: nameSize)
                        }
                        Text(name)
                            .font(.system(size: nameSize, weight: .bold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        gamesLabel(size: detailSize)
                    }
                    scoreView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(inset)
                // 非サーブ側にも同じ高さを確保し、交代しても得点の位置と大きさを変えない。
                serveBanner(height: serveHeight, width: proxy.size.width)
            }
            .foregroundStyle(theme.foreground)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(isServing ? serviceColor : .clear, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            }
        }
    }

    private func serveBanner(height: CGFloat, width: CGFloat) -> some View {
        let textSize = min(height * 0.55, width * 0.16)
        return HStack(spacing: textSize * 0.32) {
            Circle()
                .fill(theme.serveForeground)
                .frame(width: textSize * 0.72, height: textSize * 0.72)
            Text("サーブ")
                .font(.system(size: textSize, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(theme.serveForeground)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(serviceColor)
        .opacity(isServing ? 1 : 0)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var scoreView: some View {
        switch theme {
        case .simple, .focus:
            GeometryReader { proxy in
                Text("\(score)")
                    .font(.system(size: proxy.size.height * 0.91, weight: .bold,
                                  design: theme == .simple ? .rounded : .default))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        case .flip:
            FlipScore(score: score, color: accent)
        case .arena:
            ArenaScore(score: score, color: accent)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
        }
    }

    private func gamesLabel(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.35) {
            Text("ゲーム")
                .font(.system(size: size * 0.85, weight: .medium))
                .foregroundStyle(theme.foreground.opacity(0.7))
            Text("\(games)")
                .font(.system(size: size * 1.3, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme == .flip ? Color.white : theme.foreground)
                .padding(.horizontal, theme == .flip ? size * 0.5 : 0)
                .background {
                    if theme == .flip {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 0.65, green: 0.18, blue: 0.18))
                            .padding(.vertical, -2)
                    }
                }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    @ViewBuilder private var panelBackground: some View {
        switch theme {
        case .simple: Color.clear
        case .flip: Color(white: 0.1)
        case .arena:
            RoundedRectangle(cornerRadius: 16)
                .fill(accent.opacity(0.035))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(accent.opacity(0.2), lineWidth: 1)
                }
        case .focus: accent
        }
    }
}
