import SwiftUI
import TTLogCore

/// ゲームごとに、カメラが撮れているか（サムネイル・長さ・大きさ）を並べる。カメラを触らずに確かめるため。
struct ClipReportRows: View {
    let sessionId: String
    let games: [GameTimeline]

    @ObservedObject private var store = ClipReportStore.shared

    var body: some View {
        let reports = store.reports(for: sessionId)
        ForEach(games, id: \.index) { game in
            let clips = reports.filter { $0.gameIndex == game.index }
            if clips.isEmpty {
                row(title: "第\(game.index + 1)ゲーム", clip: nil)
            } else {
                ForEach(clips, id: \.file) { row(title: "第\(game.index + 1)ゲーム", clip: $0) }
            }
        }
        ForEach(reports.filter { $0.gameIndex == nil }, id: \.file) { clip in
            row(title: clip.file.hasPrefix("whole") ? "通し録画" : "手動録画", clip: clip)
        }
    }

    private func row(title: String, clip: ClipReport?) -> some View {
        HStack(spacing: 12) {
            thumbnail(clip)
                .frame(width: 128, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let clip {
                    Text("録画 \(Self.clock(clip.seconds))　\(ByteCountFormatter.string(fromByteCount: clip.bytes, countStyle: .file))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("録画なし")
                        .font(.subheadline.bold())
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder private func thumbnail(_ clip: ClipReport?) -> some View {
        if let base64 = clip?.thumbnail, let data = Data(base64Encoded: base64), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.secondary.opacity(0.15)
                Image(systemName: clip == nil ? "video.slash" : "video")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// いまの記録の録画の一覧。スコアボード右上のカメラの表示から開く。
struct ClipReportSheet: View {
    let sessionId: String
    let games: [GameTimeline]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ClipReportRows(sessionId: sessionId, games: games)
            }
            .navigationTitle("録画")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
