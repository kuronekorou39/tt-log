import Charts
import SwiftUI
import TTLogCore

/// 1回の記録の結果。ゲームごとのスコア推移・得点の一覧・サーブ別の得点と、共有。
struct SessionDetailView: View {
    let session: SessionRecord

    @State private var shareImage: Image?

    private var log: SessionLog { session.log }
    private var names: [String] { [name(0), name(1)] }

    var body: some View {
        let log = self.log
        let games = log.games().filter { !$0.points.isEmpty }
        List {
            Section {
                ResultHeader(session: session, log: log, names: names)
            }
            if !games.isEmpty {
                Section("内訳") {
                    StatsTable(stats: games.playerStats(), names: names)
                }
            }
            ForEach(games, id: \.index) { game in
                Section {
                    GameDetail(game: game, names: names)
                } header: {
                    Text(gameTitle(game))
                }
            }
            if games.isEmpty {
                Text("まだ得点がありません。").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("結果")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let shareImage {
                    ShareLink(item: shareImage, preview: SharePreview("卓球の結果", image: shareImage)) {
                        Label("画像で送る", systemImage: "photo")
                    }
                }
                ShareLink(item: ResultText.make(session: session, log: log, names: names)) {
                    Label("文字で送る", systemImage: "text.alignleft")
                }
            }
        }
        .task { renderShareImage() }
    }

    private func name(_ player: Int) -> String {
        player < session.playerNames.count ? session.playerNames[player] : (player == 0 ? "A" : "B")
    }

    private func gameTitle(_ game: GameTimeline) -> String {
        var parts = ["第\(game.index + 1)ゲーム"]
        if let last = game.points.last?.scores {
            parts.append("\(last[0]) - \(last[1])")
        }
        if let w = game.winner {
            parts.append("\(name(w)) 勝ち")
        } else {
            parts.append("途中")
        }
        if let end = game.endedAt ?? game.points.last?.at {
            parts.append(ResultText.duration(end.timeIntervalSince(game.startedAt)))
        }
        return parts.joined(separator: "　")
    }

    @MainActor
    private func renderShareImage() {
        let renderer = ImageRenderer(content: ResultCard(session: session, log: log, names: names))
        renderer.scale = 2
        if let ui = renderer.uiImage { shareImage = Image(uiImage: ui) }
    }
}

// MARK: - 部品

private struct ResultHeader: View {
    let session: SessionRecord
    let log: SessionLog
    let names: [String]

    var body: some View {
        let won = log.state.gamesWon
        VStack(alignment: .leading, spacing: 6) {
            Text(session.startedAt, format: .dateTime.year().month().day().weekday().hour().minute())
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(names[0]).font(.title.bold()).lineLimit(1)
                Text("\(won[0]) - \(won[1])").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                Text(names[1]).font(.title.bold()).lineLimit(1)
            }
            Text(log.config.format.title + (session.endedAt == nil ? "　記録中" : ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct StatsTable: View {
    let stats: [PlayerStats]
    let names: [String]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
            GridRow {
                Text("")
                Text(names[0]).bold().lineLimit(1)
                Text(names[1]).bold().lineLimit(1)
            }
            Divider()
            row("得点") { "\(stats[$0].points)" }
            row("自分のサーブで取った点") { ratio(stats[$0].servePointsWon, stats[$0].servePointsPlayed) }
            row("相手のサーブで取った点") { ratio(stats[$0].receivePointsWon, stats[$0].receivePointsPlayed) }
            row("最大連続得点") { "\(stats[$0].longestRun)" }
        }
        .monospacedDigit()
    }

    private func row(_ title: String, _ value: @escaping (Int) -> String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value(0))
            Text(value(1))
        }
    }

    private func ratio(_ won: Int, _ played: Int) -> String {
        guard played > 0 else { return "-" }
        return "\(won) / \(played)（\(Int((Double(won) / Double(played) * 100).rounded()))%）"
    }
}

/// 1ゲームのスコア推移のグラフと、得点の一覧。
private struct GameDetail: View {
    let game: GameTimeline
    let names: [String]

    @State private var showPoints = false

    private static let colors: [Color] = [.blue, .orange]

    var body: some View {
        Chart {
            ForEach(Array(game.points.enumerated()), id: \.offset) { i, point in
                ForEach(0..<2, id: \.self) { p in
                    LineMark(x: .value("点", i + 1), y: .value("得点", point.scores[p]))
                        .foregroundStyle(by: .value("選手", names[p]))
                        .interpolationMethod(.stepEnd)
                }
            }
        }
        .chartForegroundStyleScale(domain: names, range: Self.colors)
        .chartXAxisLabel("何点目")
        .frame(height: 160)
        .padding(.vertical, 4)

        DisclosureGroup("得点の一覧（\(game.points.count)点）", isExpanded: $showPoints) {
            ForEach(Array(game.points.enumerated()), id: \.offset) { i, point in
                HStack(spacing: 12) {
                    Text("\(i + 1)").foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    Text("\(point.scores[0]) - \(point.scores[1])").bold()
                    Text(names[point.winner])
                        .foregroundStyle(Self.colors[point.winner])
                        .lineLimit(1)
                    Spacer()
                    Text("サーブ \(names[point.server])").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: point.source == .voice ? "mic" : "hand.tap")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(point.source == .voice ? "声" : "タップ")
                    Text(point.at, format: .dateTime.hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
    }
}

/// 画像で共有するときのカード。端末の見た目の設定に左右されないよう、色を固定する。
private struct ResultCard: View {
    let session: SessionRecord
    let log: SessionLog
    let names: [String]

    var body: some View {
        let won = log.state.gamesWon
        let games = log.games().filter { !$0.points.isEmpty }
        let stats = games.playerStats()
        VStack(spacing: 16) {
            Text("卓球の記録　\(session.startedAt.formatted(.dateTime.year().month().day()))")
                .font(.title3)
                .foregroundStyle(.gray)
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(names[0]).font(.system(size: 34, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
                Text("\(won[0]) - \(won[1])").font(.system(size: 56, weight: .heavy, design: .rounded))
                Text(names[1]).font(.system(size: 34, weight: .bold)).lineLimit(1).minimumScaleFactor(0.5)
            }
            VStack(spacing: 6) {
                ForEach(games, id: \.index) { g in
                    let s = g.points.last?.scores ?? [0, 0]
                    HStack {
                        Text("第\(g.index + 1)ゲーム").foregroundStyle(.gray)
                        Spacer()
                        Text("\(s[0])").fontWeight(g.winner == 0 ? .heavy : .regular)
                        Text("-")
                        Text("\(s[1])").fontWeight(g.winner == 1 ? .heavy : .regular)
                        Spacer()
                        Text(g.winner == nil ? "途中" : "").foregroundStyle(.gray).frame(width: 40)
                    }
                    .font(.title3.monospacedDigit())
                }
            }
            .padding(.horizontal, 40)
            if stats.count == 2, stats[0].points + stats[1].points > 0 {
                Text("得点 \(stats[0].points) - \(stats[1].points)　最大連続 \(stats[0].longestRun) / \(stats[1].longestRun)")
                    .font(.callout)
                    .foregroundStyle(.gray)
            }
        }
        .padding(32)
        .frame(width: 600)
        .background(Color.white)
        .foregroundStyle(Color.black)
        .environment(\.colorScheme, .light)
    }
}

/// 文字で共有するときの本文。
enum ResultText {
    static func make(session: SessionRecord, log: SessionLog, names: [String]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd HH:mm"
        var lines = ["卓球の記録 \(f.string(from: session.startedAt))", log.summary(names: names)]
        for g in log.games() where !g.points.isEmpty {
            if let last = g.points.last?.scores {
                let note = g.winner == nil ? "（途中）" : ""
                lines.append("第\(g.index + 1)ゲーム \(names[0]) \(last[0]) - \(last[1]) \(names[1])\(note)")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        return "\(s / 60)分\(String(format: "%02d", s % 60))秒"
    }
}
