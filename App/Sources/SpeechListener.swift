import AVFoundation
import Speech
import TTLogCore

/// マイクの音声を端末内で認識し、発話ごとに操作へ変換する。
///
/// 発話の区切り：認識結果の更新が `silenceInterval` 秒止まったら1発話とみなし、
/// 認識タスクを作り直す（1タスク = 1発話 にして、前の発話の文字が混ざらないようにする）。
@MainActor
final class SpeechListener: ObservableObject {
    struct Utterance: Identifiable {
        let id = UUID()
        let time: Date
        let text: String
        let reading: String
        let command: VoiceCommand?
        let accepted: Bool
    }

    @Published private(set) var isListening = false
    @Published private(set) var partialText = ""
    @Published private(set) var statusMessage = ""
    @Published private(set) var log: [Utterance] = []

    /// 受け付けた操作を受け取る。
    var onCommand: ((VoiceCommand) -> Void)?
    /// 受け付けなかった操作（二重反応の抑止など）を受け取る。
    var onRejected: ((VoiceCommand) -> Void)?

    var matcher = VoiceCommandMatcher(playerCallNames: [])
    var contextualStrings: [String] = []
    var gate = CommandGate(deadTime: 1.5)
    var silenceInterval: Duration = .milliseconds(600)

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private let requestBox = RequestBox()
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var currentText = ""
    private var silenceTask: Task<Void, Never>?

    private static let logLimit = 300

    /// この端末で日本語の端末内（オフライン）認識が使えるか。
    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    func start() async {
        guard !isListening else { return }
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "音声認識が使えません"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "マイクを開けません: \(error.localizedDescription)"
            return
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.installTap(on: input, box: requestBox)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            statusMessage = "録音を始められません: \(error.localizedDescription)"
            return
        }
        isListening = true
        startRecognition()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        silenceTask?.cancel()
        generation += 1
        task?.cancel()
        task = nil
        requestBox.current?.endAudio()
        requestBox.current = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        partialText = ""
        statusMessage = "停止中"
    }

    func clearLog() { log.removeAll() }

    /// 共有用のテキスト（体育館で試した結果を送る用）。
    func logText() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let lines = log.reversed().map { u in
            let result: String
            switch (u.command, u.accepted) {
            case (nil, _): result = "－"
            case (let c?, true): result = "○ \(Self.describe(c))"
            case (let c?, false): result = "× \(Self.describe(c))（二重）"
            }
            return "\(f.string(from: u.time))\t\(u.text)\t\(u.reading)\t\(result)"
        }
        return (["時刻\t認識\t読み\t結果"] + lines).joined(separator: "\n")
    }

    static func describe(_ c: VoiceCommand) -> String {
        switch c {
        case .point(let p): return p == 0 ? "A に1点" : "B に1点"
        case .undo: return "戻す"
        case .nextGame: return "次のゲーム"
        }
    }

    // MARK: - 認識

    private func startRecognition() {
        guard isListening, let recognizer else { return }
        generation += 1
        let gen = generation
        currentText = ""

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsOnDevice
        request.taskHint = .confirmation
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        requestBox.current = request
        statusMessage = supportsOnDevice ? "聞き取り中（端末内）" : "聞き取り中（端末内認識に未対応・ネット経由）"

        task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] text, isFinal, errorMessage in
            Task { @MainActor in
                self?.handle(text: text, isFinal: isFinal, errorMessage: errorMessage, generation: gen)
            }
        }
    }

    private func handle(text: String?, isFinal: Bool, errorMessage: String?, generation gen: Int) {
        guard gen == generation, isListening else { return }
        if let text, !text.isEmpty {
            currentText = text
            partialText = text
        }
        if let errorMessage, currentText.isEmpty {
            // 無音が続いたときなどに認識タスクは失敗で終わる。すぐ作り直すと失敗が続いたときに
            // 空回りするので、少し待ってから再開する。
            statusMessage = "認識を再開します（\(errorMessage)）"
            generation += 1
            task?.cancel()
            requestBox.current?.endAudio()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                self?.startRecognition()
            }
            return
        }
        if isFinal || errorMessage != nil {
            finishUtterance(generation: gen)
            return
        }
        silenceTask?.cancel()
        silenceTask = Task { [weak self, silenceInterval] in
            try? await Task.sleep(for: silenceInterval)
            guard !Task.isCancelled else { return }
            self?.finishUtterance(generation: gen)
        }
    }

    private func finishUtterance(generation gen: Int) {
        guard gen == generation else { return }
        silenceTask?.cancel()
        let text = currentText
        task?.cancel()
        requestBox.current?.endAudio()
        partialText = ""
        startRecognition()

        guard !text.isEmpty else { return }
        let reading = ReadingConverter.hiragana(text)
        let command = matcher.match(reading: reading)
        var accepted = false
        if let command {
            accepted = gate.accept(command, at: Date())
            if accepted { onCommand?(command) } else { onRejected?(command) }
        }
        log.insert(Utterance(time: Date(), text: text, reading: reading, command: command, accepted: accepted), at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
    }

    private func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard speech == .authorized else {
            statusMessage = "音声認識が許可されていません（設定アプリで許可してください）"
            return false
        }
        guard await AVAudioApplication.requestRecordPermission() else {
            statusMessage = "マイクが許可されていません（設定アプリで許可してください）"
            return false
        }
        return true
    }

    // 以下は音声スレッド／認識スレッドから呼ばれるので、メインアクターから切り離しておく。

    nonisolated private static func installTap(on node: AVAudioInputNode, box: RequestBox) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable (String?, Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            handler(result?.bestTranscription.formattedString, result?.isFinal ?? false, error?.localizedDescription)
        }
    }
}

/// いま音声を流し込む先の認識リクエスト。音声スレッドとメインスレッドの両方から触るのでロックで守る。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return request }
        set { lock.lock(); request = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        current?.append(buffer)
    }
}
