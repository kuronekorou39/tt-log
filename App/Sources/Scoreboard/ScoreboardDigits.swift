import SwiftUI

/// 桁数を固定しない。長いデュースでも切り捨てず、領域に合わせて縮小する。
struct FlipScore: View {
    let score: Int
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let digits = Array(score < 10 ? "0\(score)" : String(score))
            let spacing = max(3, proxy.size.width * 0.018)
            HStack(spacing: spacing) {
                ForEach(digits.indices, id: \.self) { index in
                    FlipDigit(digit: String(digits[index]), color: color)
                }
            }
            .padding(.top, 7)
            .padding(.bottom, 5)
        }
        .accessibilityHidden(true)
    }
}

private struct FlipDigit: View {
    let digit: String
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let radius = max(4, min(12, proxy.size.width * 0.07))
            let ringWidth = max(4, min(12, proxy.size.width * 0.075))
            let ringHeight = max(12, min(30, proxy.size.height * 0.13))
            ZStack {
                RoundedRectangle(cornerRadius: radius)
                    .fill(Color(white: 0.22))
                    .offset(y: 4)
                RoundedRectangle(cornerRadius: radius)
                    .fill(LinearGradient(colors: [Color(white: 0.18), Color(white: 0.085)],
                                         startPoint: .top, endPoint: .bottom))
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                Text(digit)
                    .font(.system(size: proxy.size.height * 0.86, weight: .bold, design: .rounded))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
                    .padding(.horizontal, 3)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                HStack {
                    ring(width: ringWidth, height: ringHeight)
                    Spacer(minLength: 0)
                    ring(width: ringWidth, height: ringHeight)
                }
                .padding(.horizontal, proxy.size.width * 0.22)
                .frame(maxHeight: .infinity, alignment: .top)
                .offset(y: -ringHeight * 0.25)
            }
        }
    }

    private func ring(width: CGFloat, height: CGFloat) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.78), Color(white: 0.3)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.6), radius: 1, y: 2)
    }
}

/// フォントの追加や画像なしで描く7セグメント表示。点灯しない部分はごく薄くする。
struct ArenaScore: View {
    let score: Int
    let color: Color

    private static let segments: [[CGPoint]] = [
        [CGPoint(x: 16, y: 0), CGPoint(x: 84, y: 0), CGPoint(x: 95, y: 10), CGPoint(x: 82, y: 20), CGPoint(x: 18, y: 20), CGPoint(x: 5, y: 10)],
        [CGPoint(x: 100, y: 16), CGPoint(x: 100, y: 78), CGPoint(x: 90, y: 88), CGPoint(x: 80, y: 78), CGPoint(x: 80, y: 28)],
        [CGPoint(x: 100, y: 102), CGPoint(x: 100, y: 164), CGPoint(x: 80, y: 152), CGPoint(x: 80, y: 102), CGPoint(x: 90, y: 92)],
        [CGPoint(x: 18, y: 160), CGPoint(x: 82, y: 160), CGPoint(x: 95, y: 170), CGPoint(x: 84, y: 180), CGPoint(x: 16, y: 180), CGPoint(x: 5, y: 170)],
        [CGPoint(x: 0, y: 102), CGPoint(x: 10, y: 92), CGPoint(x: 20, y: 102), CGPoint(x: 20, y: 152), CGPoint(x: 0, y: 164)],
        [CGPoint(x: 0, y: 16), CGPoint(x: 20, y: 28), CGPoint(x: 20, y: 78), CGPoint(x: 10, y: 88), CGPoint(x: 0, y: 78)],
        [CGPoint(x: 18, y: 80), CGPoint(x: 82, y: 80), CGPoint(x: 92, y: 90), CGPoint(x: 82, y: 100), CGPoint(x: 18, y: 100), CGPoint(x: 8, y: 90)],
    ]
    private static let litSegments: [Set<Int>] = [
        [0, 1, 2, 3, 4, 5], [1, 2], [0, 1, 6, 4, 3], [0, 1, 2, 3, 6], [5, 6, 1, 2],
        [0, 5, 6, 2, 3], [0, 5, 4, 3, 2, 6], [0, 1, 2], [0, 1, 2, 3, 4, 5, 6], [0, 1, 2, 3, 5, 6],
    ]

    var body: some View {
        Canvas { context, size in
            let digits = (score < 10 ? "0\(score)" : String(score)).compactMap(\.wholeNumberValue)
            let width = CGFloat(digits.count) * 100 + CGFloat(max(0, digits.count - 1)) * 22
            let scale = max(0, min(size.width / width, size.height / 180))
            let origin = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - 180 * scale) / 2)
            for (position, digit) in digits.enumerated() {
                for (index, points) in Self.segments.enumerated() {
                    let path = Path { path in
                        for (vertex, point) in points.enumerated() {
                            let p = CGPoint(x: origin.x + (CGFloat(position) * 122 + point.x) * scale,
                                            y: origin.y + point.y * scale)
                            if vertex == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        path.closeSubpath()
                    }
                    context.fill(path, with: .color(color.opacity(Self.litSegments[digit].contains(index) ? 1 : 0.055)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
