import Foundation
import TTLogCore

/// カメラから届いた録画の報告を、記録ごとに残す。履歴から結果を開いたときにも見られるようにする。
///
/// 置き場所：Application Support / ClipReports / <記録の ID>.json
@MainActor
final class ClipReportStore: ObservableObject {
    static let shared = ClipReportStore()

    @Published private var bySession: [String: [ClipReport]] = [:]

    private let folder: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("ClipReports", isDirectory: true)
    }

    /// その記録の報告（ファイル名の順）。
    func reports(for sessionId: String) -> [ClipReport] {
        if let loaded = bySession[sessionId] { return loaded }
        guard let data = try? Data(contentsOf: file(sessionId)),
              let list = try? JSONDecoder().decode([ClipReport].self, from: data) else { return [] }
        // 表示の途中で値を書き換えないよう、読み込んだものは次の機会に覚える
        Task { [weak self] in
            if self?.bySession[sessionId] == nil { self?.bySession[sessionId] = list }
        }
        return list
    }

    /// 同じファイルの報告は置き換える（つなぎ直すとカメラが送り直すため）。
    func add(_ report: ClipReport) {
        var list = reports(for: report.sessionId).filter { $0.file != report.file }
        list.append(report)
        list.sort { $0.file < $1.file }
        bySession[report.sessionId] = list
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) {
            try? data.write(to: file(report.sessionId), options: .atomic)
        }
    }

    private func file(_ sessionId: String) -> URL {
        folder.appendingPathComponent(sessionId + ".json")
    }
}
