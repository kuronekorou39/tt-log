import AVFoundation
import UIKit

/// カメラの録画。超広角（なければ広角）・1080p・60fps・HEVC。
///
/// 1ファイル = 1ゲーム。ファイルは10秒ごとに区切って書くので、途中でアプリが落ちても
/// それまでの分は残る（movieFragmentInterval）。
/// AVCaptureSession の操作は専用のキューで行い、画面向けの値はメインスレッドで更新する。
final class CameraRecorder: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var formatDescription = ""
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()

    /// 録画が始まったとき（メインスレッドで呼ぶ）。
    var onStarted: ((URL, Date) -> Void)?
    /// 録画が終わったとき（メインスレッドで呼ぶ）。失敗しても途中までのファイルは残っていることがある。
    var onFinished: ((URL, Error?) -> Void)?

    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "camera.session")
    private var configured = false

    private static let fragmentSeconds = 10.0

    /// カメラとマイクの許可を求めてから、プレビューを動かし始める。
    func startSession() async {
        let video = await AVCaptureDevice.requestAccess(for: .video)
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        guard video else {
            await MainActor.run { errorMessage = "カメラが許可されていません（設定アプリで許可してください）" }
            return
        }
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            DispatchQueue.main.async { self.isRunning = running }
        }
    }

    func stopSession() {
        queue.async { [self] in
            if output.isRecording { output.stopRecording() }
            session.stopRunning()
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    /// - Parameter rotationAngle: 録画の向き（画面の向きに合わせる）。
    func startRecording(to url: URL, rotationAngle: CGFloat) {
        queue.async { [self] in
            guard session.isRunning, !output.isRecording else { return }
            if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(rotationAngle) {
                conn.videoRotationAngle = rotationAngle
            }
            output.startRecording(to: url, recordingDelegate: self)
        }
    }

    func stopRecording() {
        queue.async { [self] in
            if output.isRecording { output.stopRecording() }
        }
    }

    // MARK: -

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input) else {
            report("カメラを使えません")
            return
        }
        session.addInput(input)

        // 音も残す（あとでボール音や声を解析に使えるように）
        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let lens = device.deviceType == .builtInUltraWideCamera ? "超広角" : "広角"
        let fps = selectFormat(device)

        guard session.canAddOutput(output) else {
            report("録画の出力を作れません")
            return
        }
        session.addOutput(output)
        output.movieFragmentInterval = CMTime(seconds: Self.fragmentSeconds, preferredTimescale: 600)
        var codec = "H.264"
        if let conn = output.connection(with: .video) {
            if output.availableVideoCodecTypes.contains(.hevc) {
                output.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: conn)
                codec = "HEVC"
            }
            // 手ぶれ補正は画角が狭くなるので切る（三脚に固定する前提）
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off }
        }
        configured = true
        let text = "\(lens) 1080p \(fps)fps \(codec)"
        DispatchQueue.main.async { self.formatDescription = text }
    }

    /// 1080p で 60fps が出る形式を選ぶ。選べた fps を返す。
    private func selectFormat(_ device: AVCaptureDevice) -> Int {
        let target = 60.0
        let candidates = device.formats.filter { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return d.width == 1920 && d.height == 1080
                && f.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= target }
        }
        guard let format = candidates.first else {
            report("1080p 60fps に対応する形式がないため、標準の設定で録画します")
            return 30
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let frame = CMTime(value: 1, timescale: CMTimeScale(target))
            device.activeVideoMinFrameDuration = frame
            device.activeVideoMaxFrameDuration = frame
            device.unlockForConfiguration()
            return Int(target)
        } catch {
            report("カメラの設定を変えられません: \(error.localizedDescription)")
            return 30
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { self.errorMessage = message }
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        let now = Date()
        DispatchQueue.main.async {
            self.isRecording = true
            self.onStarted?(fileURL, now)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        var result = error
        // エラー付きでも「録画自体は最後まで書けた」場合がある
        if let e = error as NSError?, (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) == true {
            result = nil
        }
        DispatchQueue.main.async {
            self.isRecording = false
            self.onFinished?(outputFileURL, result)
        }
    }
}
