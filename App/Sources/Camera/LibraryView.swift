import AVKit
import SwiftUI

/// カメラ端末での振り返り。記録 → ゲーム → 録画、と選び、得点の一覧からその場面へ飛ぶ。
struct LibraryView: View {
    @ObservedObject var library: CameraLibrary
    let deviceLog: DeviceLog
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: CameraSessionIndex?

    var body: some View {
        List {
            if library.sessions.isEmpty {
                Text("まだ録画がありません")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.sessions) { index in
                NavigationLink {
                    SessionClipsView(library: library, deviceLog: deviceLog, index: index)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(index.startedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.headline)
                        Text("\(index.name(0)) 対 \(index.name(1))　録画 \(index.clips.count) 本")
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("削除", role: .destructive) { deleting = index }
                }
            }
        }
        .navigationTitle("振り返り")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink {
                    DeviceLogListView(log: deviceLog)
                } label: {
                    Label("温度・電池", systemImage: "thermometer.medium")
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("閉じる") { dismiss() }
            }
        }
        .onAppear { library.reload() }
        .confirmationDialog("この記録の録画をすべて削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) {
                if let deleting { library.delete(deleting) }
                deleting = nil
            }
        }
    }
}

private struct SessionClipsView: View {
    @ObservedObject var library: CameraLibrary
    let deviceLog: DeviceLog
    let index: CameraSessionIndex

    var body: some View {
        List {
            Section("録画") {
                ForEach(index.clips) { clip in
                    NavigationLink {
                        ClipPlayerView(library: library, index: index, clip: clip)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(title(clip)).font(.headline)
                                Text(detail(clip)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let g = clip.gameIndex, let last = index.game(g)?.points.last {
                                Text("\(last.scores[0]) - \(last.scores[1])")
                                    .font(.title3.monospacedDigit())
                            }
                        }
                    }
                }
            }
            let samples = deviceSamples
            if !samples.isEmpty {
                Section("この記録の間の温度・電池") {
                    DeviceLogChart(samples: samples)
                        .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("\(index.name(0)) 対 \(index.name(1))")
    }

    /// 最初の録画の少し前から、最後の録画の少し後まで。
    private var deviceSamples: [DeviceSample] {
        let margin: TimeInterval = 5 * 60
        let start = (index.clips.map(\.startedAt).min() ?? index.startedAt).addingTimeInterval(-margin)
        let end = (index.clips.compactMap(\.endedAt).max() ?? Date()).addingTimeInterval(margin)
        return deviceLog.samples(from: start, to: end)
    }

    private func title(_ clip: CameraSessionIndex.Clip) -> String {
        if clip.wholeSession == true { return "通し録画（\(clip.file)）" }
        guard let g = clip.gameIndex else { return "手動録画" }
        let parts = index.clips.filter { $0.gameIndex == g }
        return parts.count > 1 ? "第\(g + 1)ゲーム（\(clip.file)）" : "第\(g + 1)ゲーム"
    }

    private func detail(_ clip: CameraSessionIndex.Clip) -> String {
        var items: [String] = [clip.startedAt.formatted(date: .omitted, time: .shortened)]
        if let end = clip.endedAt {
            let s = Int(end.timeIntervalSince(clip.startedAt))
            items.append("\(s / 60)分\(s % 60)秒")
        } else {
            items.append("終了時刻なし（途中で止まった可能性）")
        }
        if let size = library.fileSize(of: clip, in: index) {
            items.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        return items.joined(separator: "　")
    }
}

/// 録画の再生。右の一覧で得点を選ぶと、その少し前（ラリーの始まりあたり）から再生する。
private struct ClipPlayerView: View {
    let library: CameraLibrary
    let index: CameraSessionIndex
    let clip: CameraSessionIndex.Clip

    @State private var player: AVPlayer?

    /// 得点が入力された時刻から、どれだけ前から再生するか（ラリーの長さのめやす）。
    private static let rallyLeadSeconds = 8.0

    private struct Entry {
        var gameIndex: Int
        var mark: CameraSessionIndex.Mark
    }

    /// この録画に映っている得点。通し録画・手動録画は、ゲームをまたいで時刻で拾う。
    private var marks: [Entry] {
        let end = clip.endedAt ?? .distantFuture
        let games = clip.gameIndex.map { g in index.games.filter { $0.gameIndex == g } } ?? index.games
        return games.sorted { $0.gameIndex < $1.gameIndex }.flatMap { game in
            game.points.filter { $0.at >= clip.startedAt && $0.at <= end }.map { Entry(gameIndex: game.gameIndex, mark: $0) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(.black)
            if !marks.isEmpty {
                List(Array(marks.enumerated()), id: \.offset) { _, entry in
                    let mark = entry.mark
                    Button {
                        seek(to: mark)
                    } label: {
                        HStack {
                            if clip.gameIndex == nil {
                                Text("G\(entry.gameIndex + 1)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(mark.scores[0]) - \(mark.scores[1])")
                                .font(.headline.monospacedDigit())
                            Text(index.name(mark.winner))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(offsetText(mark)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 260)
                .listStyle(.plain)
            }
        }
        .navigationTitle(clip.gameIndex.map { "第\($0 + 1)ゲーム" } ?? (clip.wholeSession == true ? "通し録画" : "手動録画"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback)
            player = AVPlayer(url: library.url(of: clip, in: index))
        }
        .onDisappear {
            player?.pause()
            // 録画に戻ったときにマイクが使えるよう、音声の設定を戻す
            try? AVAudioSession.sharedInstance().setCategory(.playAndRecord, options: [.defaultToSpeaker, .mixWithOthers])
        }
    }

    private func seek(to mark: CameraSessionIndex.Mark) {
        let t = max(0, mark.at.timeIntervalSince(clip.startedAt) - Self.rallyLeadSeconds)
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
    }

    private func offsetText(_ mark: CameraSessionIndex.Mark) -> String {
        let s = Int(mark.at.timeIntervalSince(clip.startedAt))
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}
