import AVFoundation
import TTLogCore
import UIKit

/// 録画1本の長さ・大きさ・サムネイルをまとめて、スコアボードへの報告を作る。
/// サムネイルは録画の隣に `<ファイル名>.jpg` として残し、送り直すときに使い回す。
enum ClipReporter {
    private static let thumbnailWidth: CGFloat = 480

    /// - Parameter thumbnailAt: サムネイルにする位置（録画の先頭からの秒）。
    static func report(sessionId: String, gameIndex: Int?, url: URL, thumbnailAt: Double) async -> ClipReport? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let bytes = values?.fileSize else { return nil }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let seconds = duration.isFinite ? duration : 0
        let cache = url.appendingPathExtension("jpg")
        var jpeg = try? Data(contentsOf: cache)
        if jpeg == nil, seconds > 0 {
            jpeg = await thumbnail(asset, at: max(0, min(thumbnailAt, seconds - 0.2)))
            if let jpeg { try? jpeg.write(to: cache, options: .atomic) }
        }
        return ClipReport(sessionId: sessionId, gameIndex: gameIndex, file: url.lastPathComponent,
                          seconds: seconds, bytes: Int64(bytes), thumbnail: jpeg?.base64EncodedString())
    }

    private static func thumbnail(_ asset: AVURLAsset, at seconds: Double) async -> Data? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailWidth, height: thumbnailWidth)
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let result = try? await generator.image(at: time) else { return nil }
        return UIImage(cgImage: result.image).jpegData(compressionQuality: 0.6)
    }
}
