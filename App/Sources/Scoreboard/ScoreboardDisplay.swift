import SwiftUI
import TTLogCore

/// 実画面とデザイン選択の見本で共用する表示。得点操作は呼び出し元に渡す。
struct ScoreboardDisplay: View {
    let theme: ScoreboardTheme
    let state: MatchState
    let playerNames: [String]
    /// いまのゲームで最後に点を取った選手。サーブの目印と取り違えないよう、別の形で示す。
    var lastScorer: Int? = nil
    /// 選手ごとの呼び方の札。空なら帯を出さない。
    var callTags: [CallTag] = []
    var onPoint: (Int) -> Void = { _ in }
    /// 二本指のタップ。nil なら受けない（デザインの見本など）。
    var onUndo: (() -> Void)?

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = theme == .simple ? 0 : min(20, proxy.size.width * 0.018)
            HStack(spacing: theme == .simple ? 0 : inset) {
                panel(player: state.left)
                if theme == .simple { Divider() }
                panel(player: 1 - state.left)
            }
            // パネルのボタンは VoiceOver 用に残し、指のタップはこの層で受ける
            .overlay {
                if let onUndo {
                    ScoreboardTapLayer { point in
                        guard state.phase == .playing else { return }
                        onPoint(point.x < proxy.size.width / 2 - inset ? state.left : 1 - state.left)
                    } onTwoFingerTap: {
                        onUndo()
                    }
                }
            }
            .padding(inset)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(theme.background)
    }

    private func callWordNote(_ player: Int) -> String {
        callTags.indices.contains(player) ? "呼び方「" + callTags[player].word + "」、" : ""
    }

    /// ゲーム（または試合）に勝った選手。ゲーム中は nil。
    private var winner: (player: Int, matchOver: Bool)? {
        switch state.phase {
        case .playing: return nil
        case .gameOver(let w): return (w, false)
        case .matchOver(let w): return (w, true)
        }
    }

    private func panel(player: Int) -> some View {
        let name = playerNames.indices.contains(player) ? playerNames[player] : (player == 0 ? "A" : "B")
        let win: Bool? = winner?.player == player ? winner?.matchOver : nil
        return Button {
            onPoint(player)
        } label: {
            ScoreboardPlayerPanel(theme: theme, player: player, name: name,
                                  score: state.scores[player],
                                  isServing: state.server == player,
                                  isLastScorer: lastScorer == player,
                                  callTag: callTags.indices.contains(player) ? callTags[player] : nil,
                                  win: win.map { $0 ? ScoreboardPlayerPanel.WinKind.match : .game },
                                  dimmed: winner != nil && win == nil)
                .contentShape(Rectangle())
        }
        .buttonStyle(ScoreboardPointButtonStyle())
        .disabled(state.phase != .playing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue("\(win != nil ? "勝ち、" : "")\(state.server == player ? "サーブ、" : "")\(lastScorer == player ? "直前に得点、" : "")\(callWordNote(player))\(state.scores[player])点")
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
    let isServing: Bool
    var isLastScorer = false
    var callTag: CallTag?
    var win: WinKind?
    /// 負けた側は少し暗くして、勝った側を目立たせる。
    var dimmed = false

    enum WinKind { case game, match }

    private var accent: Color { theme.accent(for: player) }
    private var serviceColor: Color { theme.serveHighlight(for: player) }

    var body: some View {
        GeometryReader { proxy in
            let inset = max(6, min(26, proxy.size.width * 0.055))
            let nameSize = max(12, min(40, min(proxy.size.width * 0.09, proxy.size.height * 0.12)))
            let serveHeight = min(112, max(36, proxy.size.height * 0.19))
            let borderWidth = max(3, min(9, proxy.size.width * 0.017))
            let cornerRadius: CGFloat = theme == .simple ? 0 : 16
            VStack(spacing: 0) {
                // 呼び方の帯は両方のパネルに出るので、どちらかを目立たせる印にはならない
                if let callTag {
                    CallTagBand(theme: theme, tag: callTag,
                                height: max(22, min(52, proxy.size.height * 0.08)))
                }
                VStack(spacing: max(6, min(18, proxy.size.height * 0.035))) {
                    // 名前は中央。「+1」は右端に重ね、出ても名前が動かないようにする
                    ZStack {
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
                        }
                        .padding(.horizontal, nameSize * 2)
                        if isLastScorer {
                            LastPointBadge(theme: theme, score: score, height: nameSize * 1.2)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .transition(.scale(scale: 0.3).combined(with: .opacity))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    scoreView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .padding(inset)
                .animation(.spring(response: 0.35, dampingFraction: 0.6), value: isLastScorer)
                // 非サーブ側にも同じ高さを確保し、交代しても得点の位置と大きさを変えない。
                // ゲーム終了時はサーブがいないので、同じ場所に「勝ち」の帯を出す。
                ZStack {
                    serveBanner(height: serveHeight, width: proxy.size.width)
                    if let win {
                        WinBanner(kind: win, height: serveHeight, width: proxy.size.width)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .opacity(dimmed ? 0.55 : 1)
            .foregroundStyle(theme.foreground)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(panelBackground)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            // サーブはパネル下の帯だけで示す（太枠も付けると、点が入った側と取り違えやすかった）
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(win != nil ? WinBanner.color : .clear, lineWidth: borderWidth)
                    .allowsHitTesting(false)
            }
            .overlay {
                if win != nil {
                    ConfettiBurst().allowsHitTesting(false)
                }
            }
            .animation(.spring(response: 0.45, dampingFraction: 0.65), value: win)
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

/// パネルの上の、声で呼ぶ言葉の帯。色の組は帯をその色で塗り、左右の言葉は矢印を添えて控えめに出す。
private struct CallTagBand: View {
    let theme: ScoreboardTheme
    let tag: CallTag
    let height: CGFloat

    /// 左右の言葉はそれぞれ外側に寄せる。色は中央。
    private var alignment: Alignment {
        switch tag.arrow {
        case .leading: return .leading
        case .trailing: return .trailing
        case nil: return .center
        }
    }

    var body: some View {
        let size = height * 0.62
        HStack(spacing: size * 0.4) {
            if tag.arrow == .leading { Image(systemName: "arrowtriangle.left.fill") }
            Text(tag.word)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if tag.arrow == .trailing { Image(systemName: "arrowtriangle.right.fill") }
        }
        .font(.system(size: size, weight: .heavy, design: .rounded))
        .foregroundStyle(tag.text ?? theme.foreground.opacity(0.75))
        .padding(.horizontal, height * 0.4)
        .frame(maxWidth: .infinity, alignment: alignment)
        .frame(height: height)
        .background(tag.fill ?? theme.foreground.opacity(0.08))
        // 背景と同じような色（暗いデザインの黒、明るいデザインの白）でも帯の形が分かるように縁を付ける
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.foreground.opacity(0.18)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// 最後に点を取った側の名前の横に出す「+1」。点が入るたびに弾ませる。
/// サーブの帯（色付き・パネルの下）と見分けられるよう、文字色を反転した札にして上に置く。
private struct LastPointBadge: View {
    let theme: ScoreboardTheme
    let score: Int
    let height: CGFloat

    var body: some View {
        Text("+1")
            .font(.system(size: height * 0.7, weight: .heavy, design: .rounded))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(theme.background)
            .padding(.horizontal, height * 0.35)
            .frame(height: height)
            .background(Capsule().fill(theme.foreground))
            .keyframeAnimator(initialValue: 1.0, trigger: score) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(1.35, duration: 0.15)
                SpringKeyframe(1.0, duration: 0.35)
            }
            .accessibilityHidden(true)
    }
}

/// 勝った側のパネルの下に出す帯。ポップアップと違い、得点も「戻す」も隠さない。
private struct WinBanner: View {
    let kind: ScoreboardPlayerPanel.WinKind
    let height: CGFloat
    let width: CGFloat

    static let color = Color(red: 0.16, green: 0.68, blue: 0.33)

    var body: some View {
        let textSize = min(height * 0.55, width * 0.14)
        HStack(spacing: textSize * 0.3) {
            Image(systemName: "trophy.fill")
            Text(kind == .match ? "試合の勝ち" : "勝ち")
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .font(.system(size: textSize, weight: .heavy))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .background(Self.color)
        .accessibilityHidden(true)
    }
}

/// 勝ったときの短い紙吹雪。数秒で消える。動きを減らす設定のときは出さない。
private struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    @State private var finished = false

    private static let duration = 2.6
    private static let count = 70
    private static let colors: [Color] = [.yellow, .orange, .pink, .green, .blue, .purple, .red]

    var body: some View {
        if !reduceMotion, !finished {
            TimelineView(.animation) { timeline in
                Canvas { context, size in
                    let t = timeline.date.timeIntervalSince(start)
                    guard t < Self.duration else { return }
                    let fade = max(0, 1 - t / Self.duration)
                    for i in 0..<Self.count {
                        let x0 = Self.random(i, 0) * size.width
                        let y0 = -20 - Self.random(i, 1) * size.height * 0.4
                        let speed = size.height * (0.45 + Self.random(i, 2) * 0.5)
                        let sway = sin(t * 4 + Self.random(i, 3) * 6) * 18
                        let point = CGPoint(x: x0 + sway, y: y0 + speed * t)
                        guard point.y < size.height + 20 else { continue }
                        var piece = context
                        piece.translateBy(x: point.x, y: point.y)
                        piece.rotate(by: .radians(t * (3 + Self.random(i, 4) * 6)))
                        piece.fill(Path(CGRect(x: -5, y: -8, width: 10, height: 16)),
                                   with: .color(Self.colors[i % Self.colors.count].opacity(fade)))
                    }
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(Self.duration))
                finished = true
            }
        }
    }

    /// 粒ごとに決まった 0〜1 の値（毎フレーム同じ動きにするため）。
    private static func random(_ i: Int, _ k: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(k) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }
}
