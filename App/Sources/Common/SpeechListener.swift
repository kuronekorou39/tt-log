import AVFoundation
import Speech
import TTLogCore

/// マイクの音声を端末内で認識し、発話ごとに操作へ変換する。
///
/// 発話の区切り：認識結果の更新が `silenceInterval` 止まったら1発話とみなし、
/// 認識タスクを作り直す（1タスク = 1発話 にして、前の発話の文字が混ざらないようにする）。
///
/// 試作中は、発話ごとの音声（直前数秒）と認識結果をファイルに残す（`VoiceLogStore`）。
@MainActor
final class SpeechListener: ObservableObject {
    struct Utterance: Identifiable {
        let id = UUID()
        let time: Date
        /// 認識の第1候補。
        let text: String
        /// 第1候補以外の候補。
        let alternatives: [String]
        /// 発話の途中で認識結果がどう変わったか（古い順）。
        let partials: [String]
        /// 照合に使った読み（一致した候補、なければ第1候補の読み）。
        let reading: String
        let command: VoiceCommand?
        let accepted: Bool
        /// 操作語以外（スコアを口で言ったなど）で受け付けたときの説明。
        let note: String?
        let audioFile: URL?
    }

    @Published private(set) var isListening = false
    @Published private(set) var partialText = ""
    @Published private(set) var statusMessage = ""
    @Published private(set) var log: [Utterance] = []

    /// 受け付けた操作を受け取る。
    var onCommand: ((VoiceCommand) -> Void)?
    /// 受け付けなかった操作（二重反応の抑止など）を受け取る。
    var onRejected: ((VoiceCommand) -> Void)?
    /// 操作語に当てはまらなかった発話の読みを渡す。受け付けたら説明を返す（スコアを口で言った、など）。
    var onUnmatched: ((String) -> String?)?

    var matcher = VoiceCommandMatcher(playerCallNames: [])
    var contextualStrings: [String] = []

    /// 認識のヒントに渡す語。呼び名と、よく付け足す言い方、操作語、スコアの言い方。
    static func hints(callNames: [String]) -> [String] {
        let names = callNames.filter { !$0.isEmpty }
        return names + names.flatMap { ["\($0)ポイント", "\($0)点"] }
            + ["戻して", "次のゲーム", "オール", "ラブオール", "ワンラブ"]
    }
    var gate = CommandGate(deadTime: 1.5)
    var silenceInterval: Duration = .milliseconds(600)
    var taskHint: SFSpeechRecognitionTaskHint = .confirmation
    var recordsAudio = true

    let store = VoiceLogStore()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private let audioBox = AudioBox(keepSeconds: 5)
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var currentTexts: [String] = []
    private var currentPartials: [String] = []
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
            // .measurement は音声処理を切れるが再生音が小さくなるので、効果音が聞こえるよう .default にする
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "マイクを開けません: \(error.localizedDescription)"
            return
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        Self.installTap(on: input, box: audioBox)
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
        audioBox.request?.endAudio()
        audioBox.request = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        partialText = ""
        statusMessage = "停止中"
    }

    /// 画面のログと、保存した音声・ログファイルを消す。
    func clearLog() {
        log.removeAll()
        store.removeAll()
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
        currentTexts = []
        currentPartials = []
        audioBox.clearRecent()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsOnDevice
        request.taskHint = taskHint
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        audioBox.request = request
        statusMessage = supportsOnDevice ? "聞き取り中（端末内）" : "聞き取り中（端末内認識に未対応・ネット経由）"

        task = Self.makeTask(recognizer: recognizer, request: request) { [weak self] texts, isFinal, errorMessage in
            Task { @MainActor in
                self?.handle(texts: texts, isFinal: isFinal, errorMessage: errorMessage, generation: gen)
            }
        }
    }

    private func handle(texts: [String], isFinal: Bool, errorMessage: String?, generation gen: Int) {
        guard gen == generation, isListening else { return }
        if let best = texts.first, !best.isEmpty {
            currentTexts = texts
            partialText = best
            if currentPartials.last != best { currentPartials.append(best) }
        }
        if let errorMessage, currentTexts.isEmpty {
            // 無音が続いたときなどに認識タスクは失敗で終わる。すぐ作り直すと失敗が続いたときに
            // 空回りするので、少し待ってから再開する。
            statusMessage = "認識を再開します（\(errorMessage)）"
            generation += 1
            task?.cancel()
            audioBox.request?.endAudio()
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
        let texts = currentTexts
        let partials = currentPartials
        let audio = audioBox.takeRecent()
        task?.cancel()
        audioBox.request?.endAudio()
        partialText = ""
        startRecognition()

        guard let best = texts.first, !best.isEmpty else { return }
        let now = Date()

        // 第1候補だけでなく、他の候補のどれかが語彙と一致すれば受け付ける
        var reading = ReadingConverter.hiragana(best)
        var command: VoiceCommand?
        for text in texts {
            let r = ReadingConverter.hiragana(text)
            if let c = matcher.match(reading: r) {
                reading = r
                command = c
                break
            }
        }
        var accepted = false
        var note: String?
        if let command {
            accepted = gate.accept(command, at: now)
            if accepted { onCommand?(command) } else { onRejected?(command) }
        } else if let onUnmatched {
            // 英字で返ったスコア（「Three all」）は読みに直すと崩れるので、元の文でも試す
            search: for text in texts {
                for r in [ReadingConverter.hiragana(text), text] {
                    if let n = onUnmatched(r) {
                        reading = r
                        note = n
                        accepted = true
                        break search
                    }
                }
            }
        }

        let audioFile = recordsAudio ? store.saveAudio(audio, at: now) : nil
        let u = Utterance(
            time: now, text: best, alternatives: Array(texts.dropFirst()), partials: partials,
            reading: reading, command: command, accepted: accepted, note: note, audioFile: audioFile
        )
        store.append(u)
        log.insert(u, at: 0)
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

    nonisolated private static func installTap(on node: AVAudioInputNode, box: AudioBox) {
        let format = node.outputFormat(forBus: 0)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.append(buffer)
        }
    }

    nonisolated private static func makeTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        handler: @escaping @Sendable ([String], Bool, String?) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            // transcriptions は確からしい順。先頭が bestTranscription。
            let texts = result?.transcriptions.map(\.formattedString) ?? []
            handler(texts, result?.isFinal ?? false, error?.localizedDescription)
        }
    }
}

/// マイクの音声の受け渡し口。音声スレッドとメインスレッドの両方から触るのでロックで守る。
/// - いまの認識リクエストへ音声を流す
/// - 直近 `keepSeconds` 秒の音声を手元に残す（発話の音声を保存するため）
private final class AudioBox: @unchecked Sendable {
    private let lock = NSLock()
    private let keepSeconds: Double
    private var _request: SFSpeechAudioBufferRecognitionRequest?
    private var recent: [AVAudioPCMBuffer] = []
    private var recentFrames: AVAudioFramePosition = 0

    init(keepSeconds: Double) {
        self.keepSeconds = keepSeconds
    }

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        guard let copy = Self.copy(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        recent.append(copy)
        recentFrames += AVAudioFramePosition(copy.frameLength)
        let maxFrames = AVAudioFramePosition(keepSeconds * buffer.format.sampleRate)
        while recentFrames > maxFrames, let first = recent.first {
            recentFrames -= AVAudioFramePosition(first.frameLength)
            recent.removeFirst()
        }
    }

    func takeRecent() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        let out = recent
        recent = []
        recentFrames = 0
        return out
    }

    func clearRecent() { _ = takeRecent() }

    /// タップで渡されるバッファは使い回されることがあるので、中身を写して持つ。
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let dst = copy.floatChannelData else { return nil }
        copy.frameLength = buffer.frameLength
        let n = Int(buffer.frameLength)
        let channels = buffer.format.isInterleaved ? 1 : Int(buffer.format.channelCount)
        let samplesPerChannel = buffer.format.isInterleaved ? n * Int(buffer.format.channelCount) : n
        for ch in 0..<channels {
            dst[ch].update(from: src[ch], count: samplesPerChannel)
        }
        return copy
    }
}
