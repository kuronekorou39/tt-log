import Foundation

/// 端末の状態の記録1件。長時間録画での発熱・電池の減り方をあとで確かめるため。
struct DeviceSample: Hashable, Identifiable {
    var at: Date
    /// 温度の段階。0 正常 / 1 やや高い / 2 高い / 3 危険（iOS は温度を度数では教えてくれない）。
    var thermal: Int
    /// 電池の残り（%）。わからないときは nil。
    var battery: Int?
    var charging: Bool
    var freeBytes: Int64?
    var recording: Bool
    /// 録画の中断・撮り直しなどの出来事。
    var note: String?

    var id: Date { at }

    static let thermalTitles = ["正常", "やや高い", "高い", "危険"]

    static func thermalLevel(_ state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 0
        }
    }
}

/// 端末の状態を日ごとの CSV に書き足す。
///
/// 置き場所：書類フォルダ / DeviceLog / yyyy-MM-dd.csv（「ファイル」アプリや PC から取り出せる）
@MainActor
final class DeviceLog {
    let folder: URL

    private static let header = "時刻,温度,温度の段階,電池%,充電中,空き容量MB,録画中,出来事\n"

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        folder = docs.appendingPathComponent("DeviceLog", isDirectory: true)
    }

    func append(_ s: DeviceSample) {
        let url = file(for: s.at)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            // Excel で開いても文字化けしないよう BOM を付ける
            try? Data(("\u{FEFF}" + Self.header).utf8).write(to: url)
        }
        let fields = [
            Self.timeFormat.string(from: s.at),
            DeviceSample.thermalTitles[s.thermal],
            "\(s.thermal)",
            s.battery.map(String.init) ?? "",
            s.charging ? "1" : "0",
            s.freeBytes.map { "\($0 / 1_000_000)" } ?? "",
            s.recording ? "1" : "0",
            (s.note ?? "").replacingOccurrences(of: ",", with: "、"),
        ]
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((fields.joined(separator: ",") + "\n").utf8))
    }

    /// 記録のある日の CSV（新しい順）。
    func days() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "csv" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// その期間の記録。日をまたいでもよい。
    func samples(from start: Date, to end: Date) -> [DeviceSample] {
        var day = Calendar.current.startOfDay(for: start)
        var result: [DeviceSample] = []
        while day <= end {
            result += Self.load(file(for: day)).filter { $0.at >= start && $0.at <= end }
            guard let next = Calendar.current.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    static func load(_ url: URL) -> [DeviceSample] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7, let at = timeFormat.date(from: f[0]), let thermal = Int(f[2]),
                  DeviceSample.thermalTitles.indices.contains(thermal) else { return nil }
            return DeviceSample(at: at, thermal: thermal, battery: Int(f[3]), charging: f[4] == "1",
                                freeBytes: Int64(f[5]).map { $0 * 1_000_000 }, recording: f[6] == "1",
                                note: f.count > 7 && !f[7].isEmpty ? f[7] : nil)
        }
    }

    static func dayTitle(_ url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private func file(for date: Date) -> URL {
        folder.appendingPathComponent(Self.dayFormat.string(from: date) + ".csv")
    }
}
