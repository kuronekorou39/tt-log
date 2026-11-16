import SwiftUI
import TTLogCore

/// 聞き取った言葉を、離れていても読める大きさでスコアの上に出す。
/// 話している間はその文字を、言い終わったら結果（受け付けたら緑）を少しのあいだ出す。
struct HeardBanner: View {
    @ObservedObject var listener: SpeechListener
    let height: CGFloat

    /// 結果を出しておく時間（秒）。
    private static let showSeconds = 3.5

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if let content = content(now: context.date) {
                Text(content.text)
                    .font(.system(size: height * 0.6, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, height * 0.45)
                    .frame(height: height)
                    .background(Capsule().fill(content.accepted ? Color.green.opacity(0.92) : Color.black.opacity(0.72)))
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func content(now: Date) -> (text: String, accepted: Bool)? {
        if !listener.partialText.isEmpty { return (listener.partialText, false) }
        guard let u = listener.log.first, now.timeIntervalSince(u.time) < Self.showSeconds, !u.text.isEmpty else { return nil }
        if let command = u.command {
            return u.accepted ? ("○ " + label(command, heard: u.text), true) : (u.text, false)
        }
        // 「スコア 7-9（A +1）」の括弧は出さない（どちらに入ったかはスコアボードの「+1」でわかる）
        if u.accepted, let note = u.note { return ("○ " + (note.components(separatedBy: "（").first ?? note), true) }
        return (u.note == nil ? u.text : "？ " + u.text, false)
    }

    private func label(_ command: VoiceCommand, heard: String) -> String {
        // 得点は聞き取った言葉だけ
        if case .point = command { return heard }
        return SpeechListener.describe(command)
    }
}
