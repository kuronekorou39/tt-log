import Foundation

/// カメラ端末に残す記録（1回の記録 = 1フォルダ）。
///
/// 置き場所：書類フォルダ / Sessions / <開始日時>-<ID の先頭> /
/// - index.json：録画ファイルの一覧と、各ゲームの得点の時刻（この端末の時計に直したもの）
/// - game01-1.mov など：ゲームごとの録画
struct CameraSessionIndex: Codable, Identifiable, Hashable {
    struct Clip: Codable, Hashable, Identifiable {
        var file: String
        /// どのゲームの録画か。手動録画でゲームがわからないときは nil。
        var gameIndex: Int?
        var startedAt: Date
        var endedAt: Date?
        var id: String { file }
    }

    struct Mark: Codable, Hashable {
        var winner: Int
        /// この端末の時計での時刻。
        var at: Date
        var scores: [Int]
    }

    struct Game: Codable, Hashable {
        var gameIndex: Int
        var points: [Mark]
        var finished: Bool
    }

    var id: String
    var folderName: String
    var playerNames: [String]
    var startedAt: Date
    var clips: [Clip] = []
    var games: [Game] = []
    /// 記録したときの時計のずれ（スコアボード − この端末、ミリ秒）。
    var clockOffsetMs: Double?

    func game(_ index: Int) -> Game? { games.first { $0.gameIndex == index } }

    func name(_ player: Int) -> String {
        player < playerNames.count ? playerNames[player] : (player == 0 ? "A" : "B")
    }
}

@MainActor
final class CameraLibrary: ObservableObject {
    @Published private(set) var sessions: [CameraSessionIndex] = []

    let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static let folderStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        sessions = dirs.compactMap { load(folder: $0) }.sorted { $0.startedAt > $1.startedAt }
    }

    /// その ID の記録を返す。なければ作る。
    func ensure(id: String, playerNames: [String], startedAt: Date) -> CameraSessionIndex {
        if let existing = sessions.first(where: { $0.id == id }) { return existing }
        let folder = "\(Self.folderStamp.string(from: startedAt))-\(id.prefix(8))"
        let index = CameraSessionIndex(id: id, folderName: folder, playerNames: playerNames, startedAt: startedAt)
        save(index)
        return index
    }

    func save(_ index: CameraSessionIndex) {
        let dir = folder(of: index)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(index) {
            try? data.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
        }
        if let i = sessions.firstIndex(where: { $0.id == index.id }) {
            sessions[i] = index
        } else {
            sessions.insert(index, at: 0)
        }
    }

    func delete(_ index: CameraSessionIndex) {
        try? FileManager.default.removeItem(at: folder(of: index))
        sessions.removeAll { $0.id == index.id }
    }

    func folder(of index: CameraSessionIndex) -> URL {
        root.appendingPathComponent(index.folderName, isDirectory: true)
    }

    func url(of clip: CameraSessionIndex.Clip, in index: CameraSessionIndex) -> URL {
        folder(of: index).appendingPathComponent(clip.file)
    }

    func fileSize(of clip: CameraSessionIndex.Clip, in index: CameraSessionIndex) -> Int64? {
        let values = try? url(of: clip, in: index).resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    private func load(folder: URL) -> CameraSessionIndex? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("index.json")) else { return nil }
        return try? decoder.decode(CameraSessionIndex.self, from: data)
    }
}
