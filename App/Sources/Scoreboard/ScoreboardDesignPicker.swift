import SwiftUI
import TTLogCore

struct ScoreboardDesignPicker: View {
    var state: MatchState?
    var playerNames: [String] = ["プレーヤー A", "プレーヤー B"]

    @AppStorage(ScoreboardTheme.storageKey) private var themeRaw = ScoreboardTheme.simple.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var selected: ScoreboardTheme { ScoreboardTheme(rawValue: themeRaw) ?? .simple }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("見やすいスコアで、プレーに集中。")
                        .font(.title3.bold())
                    Text("タップすると切り替わります。選んだデザインは、この端末に保存されます。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(state == nil ? "サンプルスコアで表示しています。" : "現在のスコアで表示しています。試合の記録はそのままです。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                    ForEach(ScoreboardTheme.allCases) { theme in
                        designCard(theme)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("スコアボードのデザイン")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func designCard(_ theme: ScoreboardTheme) -> some View {
        let isSelected = selected == theme
        return Button {
            themeRaw = theme.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("第\((state ?? Self.sampleState).gameIndex + 1)ゲーム")
                        Spacer()
                        Text("TTLog").tracking(1.5)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.foreground.opacity(0.65))
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    ScoreboardDisplay(theme: theme, state: state ?? Self.sampleState, playerNames: playerNames)
                        .frame(height: 158)
                }
                .background(theme.background)
                .environment(\.colorScheme, theme.colorScheme ?? colorScheme)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(theme.title).font(.headline)
                        Spacer()
                        if isSelected {
                            Label("選択中", systemImage: "checkmark.circle.fill")
                                .font(.caption.bold())
                                .foregroundStyle(Color.accentColor)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(theme.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
                }
                .padding(14)
            }
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(theme.title)。\(theme.detail)")
        .accessibilityValue(isSelected ? "選択中" : "未選択")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityHint("この端末のスコアボードに使う")
        .accessibilityIdentifier("scoreboard.design.\(theme.rawValue)")
    }

    /// 実際のルールエンジンから、ゲーム数 1–2・得点 8–6 の見本を作る。
    static let sampleState: MatchState = {
        var events: [MatchEvent] = []
        for winner in [0, 1, 1] {
            events += Array(repeating: .point(winner: winner), count: 11)
            events.append(.startNextGame)
        }
        for _ in 0..<6 { events += [.point(winner: 0), .point(winner: 1)] }
        events += [.point(winner: 0), .point(winner: 0)]
        return RuleEngine.reduce(MatchConfig(firstLeft: 1), events)
    }()
}

struct ScoreboardDesignSheet: View {
    let state: MatchState?
    let playerNames: [String]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScoreboardDesignPicker(state: state, playerNames: playerNames)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("閉じる") { dismiss() }
                    }
                }
        }
    }
}

#if DEBUG
struct ScoreboardDisplay_Previews: PreviewProvider {
    private static let rightServeState = RuleEngine.reduce(
        MatchConfig(),
        Array(repeating: .point(winner: 0), count: 8) + Array(repeating: .point(winner: 1), count: 6)
    )
    private static let finishedState = RuleEngine.reduce(
        MatchConfig(), Array(repeating: .point(winner: 0), count: 11)
    )

    static var previews: some View {
        ForEach(ScoreboardTheme.allCases) { theme in
            ScoreboardDisplay(theme: theme, state: ScoreboardDesignPicker.sampleState,
                              playerNames: ["プレーヤー A", "プレーヤー B"])
                .environment(\.colorScheme, theme.colorScheme ?? .light)
                .previewLayout(.fixed(width: 1112, height: 650))
                .previewDisplayName("iPad・\(theme.title)")
            ScoreboardDisplay(theme: theme, state: ScoreboardDesignPicker.sampleState,
                              playerNames: ["長い表示名のプレーヤー A", "プレーヤー B"])
                .environment(\.colorScheme, theme.colorScheme ?? .light)
                .previewLayout(.fixed(width: 750, height: 230))
                .previewDisplayName("iPhone・\(theme.title)")
            ScoreboardDisplay(theme: theme, state: rightServeState,
                              playerNames: ["プレーヤー A", "プレーヤー B"])
                .environment(\.colorScheme, theme.colorScheme ?? .light)
                .previewLayout(.fixed(width: 1112, height: 650))
                .previewDisplayName("右サーブ・\(theme.title)")
            ScoreboardDisplay(theme: theme, state: finishedState,
                              playerNames: ["プレーヤー A", "プレーヤー B"])
                .environment(\.colorScheme, theme.colorScheme ?? .light)
                .previewLayout(.fixed(width: 750, height: 230))
                .previewDisplayName("ゲーム終了・サーブなし・\(theme.title)")
        }
    }
}
#endif
