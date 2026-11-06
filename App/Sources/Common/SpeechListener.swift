import AVFoundation
import Speech
import TTLogCore

/// マイクの音声の処理のしかた。離れた位置からの声や、体育館の反響にどれが強いかを練習で比べるための切り替え。
enum MicMode: String, CaseIterable {
    /// iOS の標準の処理。
    case standard
    /// 通話用の処理（音量の自動調整・反響を消す・雑音を抑える）。効果音が小さくなることがある。
    case voiceChat
    /// 処理なし（マイクの音そのまま）。
    case raw

    static let storageKey = "voice.micMode"

    var title: String {
        switch self {
        case .standard: return "標準"
        case .voiceChat: return "通話用（遠くの声・反響向け）"
        case .raw: return "処理なし"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "これまでと同じ設定です。"
        case .voiceChat: return "小さな声を持ち上げ、反響と雑音を抑えます。効果音が小さくなることがあります。"
        case .raw: return "マイクの音をそのまま使います。比べるための設定です。"
        }
    }

    var sessionMode: AVAudioSession.Mode {
        switch self {
        case .standard: return .default
        case .voiceChat: return .voiceChat
        case .raw: return .measurement
        }
    }
}

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
        /// そのときの聞き取りの設定と、受け付けていた言葉（あとで設定ごとに比べるため）。
        let settings: String
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
    /// スコアの形の発話が、どの候補でも決められなかったとき（1回だけ呼ぶ）。
    var onUnresolvedScore: (() -> Void)?

    var matcher = VoiceCommandMatcher(playerCallNames: [])
    var contextualStrings: [String] = []

    /// 認識のヒントに渡す語。呼び名と、よく付け足す言い方、操作語、スコアの言い方。
    static func hints(callNames: [String]) -> [String] {
        let names = callNames.filter { !$0.isEmpty }
        return names + names.flatMap { ["\($0)ポイント", "\($0)点"] }
            + ["戻して", "戻す", "取り消し", "次のゲーム", "オール", "ラブオール", "ワンラブ"]
    }
    var gate = CommandGate(deadTime: 1.5)
    var silenceInterval: Duration = .milliseconds(600)
    var taskHint: SFSpeechRecognitionTaskHint = .confirmation
    var recordsAudio = true
    /// 受け付けている言葉の要約（ログ用）。
    var wordsSummary = ""
    /// マイクの処理。聞き取り中に変えたら、聞き取りをやり直して反映する。
    var micMode = MicMode.standard {
        didSet {
            guard micMode != oldValue, isListening else { return }
            stop()
            Task { await start() }
        }
    }

    let store = VoiceLogStore()

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private let engine = AVAudioEngine()
    private let audioBox = AudioBox(keepSeconds: 5)
    private var task: SFSpeechRecognitionTask?
    private var generation = 0
    private var currentTexts: [String] = []
    private var currentPartials: [String] = []
    private var silenceTask: Task<Void, Never>?
    private var burstWatch: Task<Void, Never>?
    /// 最後に認識の文字が届いた時刻（文字にならなかった大きな音を見分けるため）。
    private var lastTextAt: Date?
    /// 最後に発話を区切った時刻。
    private var lastUtteranceAt: Date?

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
            // .measurement は音声処理を切れるが再生音が小さくなるので、既定は .default（設定で選べる）
            try session.setCategory(.playAndRecord, mode: micMode.sessionMode, options: [.defaultToSpeaker, .mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "マイクを開けません: \(error.localizedDescription)"
            return
        }

        let input = engine.inputNode
        // 通話用の処理（反響を消す・音量の自動調整）は、録音の部品の側で有効にする
        do {
            if input.isVoiceProcessingEnabled != (micMode == .voiceChat) {
                try input.setVoiceProcessingEnabled(micMode == .voiceChat)
            }
            if micMode == .voiceChat {
                // 効果音など、ほかの音を小さくしすぎない
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        } catch {
            statusMessage = "マイクの処理を切り替えられません: \(error.localizedDescription)"
        }
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
        watchBursts()
    }

    func stop() {
        guard isListening else { return }
        isListening = false
        silenceTask?.cancel()
        burstWatch?.cancel()
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
            lastTextAt = Date()
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

    private func looksLikeScore(_ text: String) -> Bool {
        !ScoreCallParser.pairs(in: ReadingConverter.hiragana(text)).isEmpty || !ScoreCallParser.pairs(in: text).isEmpty
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
        lastUtteranceAt = now

        // 認識の候補を確からしい順に見て、最初に意味が通ったものを使う。
        // 候補ごとに「操作語・名前」→「スコア」の順で試す（第1候補の「1対0」より、
        // 下位の候補の「ワン」（選手名）を優先してしまわないように）。
        // 英字で返ったスコア（「Three all」）は読みに直すと崩れるので、元の文でも試す。
        var reading = ReadingConverter.hiragana(best)
        var command: VoiceCommand?
        var accepted = false
        var note: String?
        search: for text in texts {
            for r in [ReadingConverter.hiragana(text), text] {
                if let c = matcher.match(reading: r) {
                    reading = r
                    command = c
                    break search
                }
                if let n = onUnmatched?(r) {
                    reading = r
                    note = n
                    accepted = true
                    break search
                }
            }
        }
        if let command {
            accepted = gate.accept(command, at: now)
            if accepted { onCommand?(command) } else { onRejected?(command) }
        } else if !accepted, texts.contains(where: { looksLikeScore($0) }) {
            // スコアの形をしているのに、いまの得点に照らして決められなかった
            note = "スコアとして決められない"
            onUnresolvedScore?()
        }

        let audioFile = recordsAudio ? store.saveAudio(audio, at: now) : nil
        record(Utterance(
            time: now, text: best, alternatives: Array(texts.dropFirst()), partials: partials,
            reading: reading, command: command, accepted: accepted, note: note, audioFile: audioFile,
            settings: currentSettings
        ))
    }

    private func record(_ u: Utterance) {
        store.append(u)
        log.insert(u, at: 0)
        if log.count > Self.logLimit { log.removeLast(log.count - Self.logLimit) }
    }

    private var currentSettings: String {
        let c = silenceInterval.components
        let ms = c.seconds * 1000 + c.attoseconds / 1_000_000_000_000_000
        let hint: String
        switch taskHint {
        case .confirmation: hint = "confirmation"
        case .search: hint = "search"
        case .dictation: hint = "dictation"
        default: hint = "unspecified"
        }
        return "区切り\(ms)ms 二重防止\(gate.deadTime)秒 \(hint) マイク:\(micMode.title) 言葉 \(wordsSummary)"
    }

    // MARK: - 文字にならなかった大きな音

    /// 声らしい長さの大きな音がしたのに認識の文字が届かなかったら、その音を「聞き取れず」としてログに残す。
    /// 離れた位置から呼んで反応しなかったときに、あとで数えて聞き直せるようにする。
    private func watchBursts() {
        burstWatch?.cancel()
        burstWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.checkBurst()
            }
        }
    }

    private func checkBurst() {
        guard isListening, let at = audioBox.burstAt else { return }
        // 認識の文字は声より少し遅れて届くので、しばらく待ってから判断する
        guard Date().timeIntervalSince(at) > 2.0 else { return }
        audioBox.clearBurst()
        if let lastTextAt, lastTextAt >= at { return }
        // 発話の直後の大きな音は、受け付けたときの効果音を拾ったもの
        if let lastUtteranceAt, at.timeIntervalSince(lastUtteranceAt) < 1.5 { return }
        guard currentTexts.isEmpty else { return }
        let now = Date()
        let audioFile = recordsAudio ? store.saveAudio(audioBox.snapshotRecent(), at: now) : nil
        record(Utterance(
            time: now, text: "", alternatives: [], partials: [], reading: "", command: nil, accepted: false,
            note: "聞き取れず（大きな音がしたが文字にならなかった）", audioFile: audioFile, settings: currentSettings
        ))
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
    /// 周りの音の大きさの目安（dB）。ゆっくり追いかける。
    private var floorDB: Float = -60
    /// 大きな音が続いているフレーム数。
    private var loudFrames: AVAudioFramePosition = 0
    private var _burstAt: Date?

    /// 周りの音よりこれだけ大きければ「大きな音」とみなす（dB）。
    private static let burstMarginDB: Float = 12
    /// 声らしい長さ（秒）。ボールを打つ音のような短い音は数えない。
    private static let burstMinSeconds = 0.15

    init(keepSeconds: Double) {
        self.keepSeconds = keepSeconds
    }

    var request: SFSpeechAudioBufferRecognitionRequest? {
        get { lock.lock(); defer { lock.unlock() }; return _request }
        set { lock.lock(); _request = newValue; lock.unlock() }
    }

    /// 声らしい大きな音が始まった時刻（まだ確かめていないもの）。
    var burstAt: Date? {
        lock.lock(); defer { lock.unlock() }; return _burstAt
    }

    func clearBurst() {
        lock.lock(); _burstAt = nil; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
        guard let copy = Self.copy(buffer) else { return }
        let level = Self.levelDB(copy)
        lock.lock()
        defer { lock.unlock() }
        let loud = level > floorDB + Self.burstMarginDB
        floorDB += (level - floorDB) * (loud ? 0.002 : 0.02)
        if loud {
            let before = loudFrames
            loudFrames += AVAudioFramePosition(copy.frameLength)
            let minFrames = AVAudioFramePosition(Self.burstMinSeconds * buffer.format.sampleRate)
            if before < minFrames, loudFrames >= minFrames, _burstAt == nil {
                _burstAt = Date().addingTimeInterval(-Self.burstMinSeconds)
            }
        } else {
            loudFrames = 0
        }
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

    /// 直近の音声を、手元から消さずに写して返す。
    func snapshotRecent() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    /// 1チャンネル目の音の大きさ（dB）。
    private static func levelDB(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -120 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let v = data[0][i]
            sum += v * v
        }
        return 10 * log10(sum / Float(n) + 1e-12)
    }

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
