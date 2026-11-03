import AVFoundation
import Foundation

/// 音声テストの記録をファイルに残す。
///
/// 置き場所：アプリの書類フォルダ / VoiceLogs
/// - log.tsv：発話ごとに1行（アプリを落としても残るよう、その都度追記する）
/// - audio/*.wav：発話ごとの音声（直前数秒）
///
/// 書類フォルダは「ファイル」アプリ（このiPad内 → TTLog）や、
/// Windows の「Apple Devices」アプリのファイル共有からも見える。
/// 発話がそのまま入るので、取り扱いに注意する。
@MainActor
final class VoiceLogStore {
    let root: URL
    private var audioDir: URL { root.appendingPathComponent("audio", isDirectory: true) }
    private var logFile: URL { root.appendingPathComponent("log.tsv") }

    private static let header = ["時刻", "音声", "結果", "照合した読み", "第1候補", "他の候補", "途中経過"]

    private let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f
    }()

    private let timeStamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("VoiceLogs", isDirectory: true)
    }

    /// 音声を WAV（16bit）で保存し、そのファイルの場所を返す。
    func saveAudio(_ buffers: [AVAudioPCMBuffer], at time: Date) -> URL? {
        guard let first = buffers.first else { return nil }
        do {
            try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
            let url = audioDir.appendingPathComponent("\(fileStamp.string(from: time)).wav")
            let format = first.format
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let file = try AVAudioFile(
                forWriting: url, settings: settings,
                commonFormat: format.commonFormat, interleaved: format.isInterleaved
            )
            for b in buffers { try file.write(from: b) }
            return url
        } catch {
            return nil
        }
    }

    func append(_ u: SpeechListener.Utterance) {
        let result: String
        switch (u.command, u.accepted) {
        case (nil, true): result = "○ \(u.note ?? "")"
        case (nil, false): result = "－"
        case (let c?, true): result = "○ \(SpeechListener.describe(c))"
        case (let c?, false): result = "× \(SpeechListener.describe(c))（二重）"
        }
        let fields = [
            timeStamp.string(from: u.time),
            u.audioFile.map { "audio/\($0.lastPathComponent)" } ?? "",
            result,
            u.reading,
            u.text,
            u.alternatives.joined(separator: "｜"),
            u.partials.joined(separator: "｜"),
        ]
        appendLine(fields)
    }

    /// VoiceLogs フォルダ全体を zip にして、一時フォルダに置いた場所を返す。
    func exportArchive() throws -> URL {
        guard FileManager.default.fileExists(atPath: logFile.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("ttlog-voicelog-\(fileStamp.string(from: Date())).zip")
        var coordError: NSError?
        var copyError: Error?
        // .forUploading を指定すると、フォルダを zip にしたものを渡してくれる
        NSFileCoordinator().coordinate(readingItemAt: root, options: .forUploading, error: &coordError) { zipURL in
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zipURL, to: dest)
            } catch {
                copyError = error
            }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        return dest
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }

    private func appendLine(_ fields: [String]) {
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let clean = fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
            var text = clean.joined(separator: "\t") + "\n"
            if !FileManager.default.fileExists(atPath: logFile.path) {
                // Excel で開いても文字化けしないよう BOM を付ける
                text = "\u{FEFF}" + Self.header.joined(separator: "\t") + "\n" + text
                try text.write(to: logFile, atomically: true, encoding: .utf8)
                return
            }
            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            // 記録の失敗で聞き取りは止めない
        }
    }
}
