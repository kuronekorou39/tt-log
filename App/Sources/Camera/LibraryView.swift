import AVKit
import SwiftUI

/// カメラ端末での振り返り。記録 → ゲーム → 録画、と選び、得点の一覧からその場面へ飛ぶ。
struct LibraryView: View {
    @ObservedObject var library: CameraLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var deleting: CameraSessionIndex?

    var body: some View {
        List {
            if library.sessions.isEmpty {
                Text("まだ録画がありません。")
                    .foregroundStyle(.secondary)
            }
            ForEach(library.sessions) { index in
                NavigationLink {
                    SessionClipsView(library: library, index: index)
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
    let index: CameraSessionIndex

    var body: some View {
        List(index.clips) { clip in
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
        .navigationTitle("\(index.name(0)) 対 \(index.name(1))")
    }

    private func title(_ clip: CameraSessionIndex.Clip) -> String {
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

    private var marks: [CameraSessionIndex.Mark] {
        guard let g = clip.gameIndex else { return [] }
        let end = clip.endedAt ?? .distantFuture
        return (index.game(g)?.points ?? []).filter { $0.at >= clip.startedAt && $0.at <= end }
    }

    var body: some View {
        HStack(spacing: 0) {
            VideoPlayer(player: player)
                .background(.black)
            if !marks.isEmpty {
                List(Array(marks.enumerated()), id: \.offset) { _, mark in
                    Button {
                        seek(to: mark)
                    } label: {
                        HStack {
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
        .navigationTitle(clip.gameIndex.map { "第\($0 + 1)ゲーム" } ?? "手動録画")
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
