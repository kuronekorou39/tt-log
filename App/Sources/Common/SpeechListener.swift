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
        case .standard: return "iOS の標準"
        case .voiceChat: return "小声と反響に強い"
        case .raw: return "加工なし"
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

/// 受信機に2台のマイクをつないだとき（ステレオ：1台目が左、2台目が右）、どちらの声を聞き取るか。
/// 発話の録音はいつも両方を残す。
enum MicPick: String, CaseIterable, Identifiable {
    case both, first, second

    static let storageKey = "voice.micPick"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return "両方"
        case .first: return "1台目"
        case .second: return "2台目"
        }
    }

    /// 聞き取りに使うチャンネル。nil は全部を混ぜる。
    var channel: Int? {
        switch self {
        case .both: return nil
        case .first: return 0
        case .second: return 1
        }
    }
}

/// マイクの音声を端末内で認識し、発話ごとに操作へ変換する。
///
/// 発話の区切り：認識結果の更新が `silenceInterval` 止まったら1発話とみなし、
/// 認識タスクを作り直す（1タスク = 1発話 にして、前の発話の文字が混ざらないようにする）。
///
/// 即時モード（既定）：話している途中の文字から得点の言葉を見つけたら、区切りを待たずに反映する（`WordSpotter`）。
/// 言葉の後ろに続きがなければ `instantConfirm` だけ待ってから受け付ける（「右に行く」で点を入れないため）。
/// スコアの言い方と操作語（戻す・リセットなど）は、これまで通り発話の区切りで判定する。
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
    /// いま使っているマイクとスピーカーの名前（画面とログに出す）。
    @Published private(set) var inputName = ""
    @Published private(set) var outputName = ""
    /// 効果音が内蔵スピーカー以外（つないだ受信機など）から出ているか。
    @Published private(set) var outputIsExternal = false
    /// 受信機のマイクのチャンネル数（2ならマイク2台を左右に分けて受け取れる）。
    @Published private(set) var receiverChannels = 0

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

    /// 認識のヒントに渡す語。呼び名と、よく付け足す言い方、操作語、スコアの言い方、卓球の用語。
    static func hints(callNames: [String]) -> [String] {
        let names = callNames.filter { !$0.isEmpty }
        return names + names.flatMap { ["\($0)ポイント", "\($0)点"] }
            + ["戻して", "戻す", "戻せ", "元に戻す", "取り消し", "進める", "次のゲーム", "ネクストゲーム", "ネクスト", "次行こう", "入れ替え", "リセット",
               "オール", "ラブオール", "ワンラブ"]
            + VoiceCommandMatcher.terms.map(\.label) + ["ジュース"]
    }
    var gate = CommandGate(deadTime: 1.5)
    var silenceInterval: Duration = .milliseconds(600)
    /// 話している途中の文字で、得点の言葉を即座に反映するか。
    var instantMode = true
    /// 言葉の後ろに何も続かないとき、続きが来ないか見る時間。
    var instantConfirm: Duration = .milliseconds(300)
    /// スコアの形（「フォーファイブ」）になったあと、続きが来ないか見る時間。
    /// 数は続きが付きやすい（「じゅういち」のあとに「きゅう」）ので、言葉より少し長く待つ。
    var scoreConfirm: Duration = .milliseconds(500)
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

    /// 受信機のどちらのマイクを聞き取るか。
    var micPick = MicPick.both {
        didSet { audioBox.listenChannel = micPick.channel }
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
    private var confirmTask: Task<Void, Never>?
    /// いまの発話で即時に反映した操作と、言葉が出てから反映までの秒数。
    private var instantFired: [(command: VoiceCommand, accepted: Bool, delay: Double)] = []
    /// いまの発話で見つけた言葉（続きがくっついたものを除く）が、最初に文字に出た時刻。
    private var instantSeenAt: [Date] = []
    private var burstWatch: Task<Void, Never>?
    /// 最後に認識の文字が届いた時刻（文字にならなかった大きな音を見分けるため）。
    private var lastTextAt: Date?
    /// 最後に発話を区切った時刻。
    private var lastUtteranceAt: Date?
    /// いまの認識を始めた時刻。
    private var taskStartedAt: Date?
    /// いまの認識は、聞き取れなかった声の聞き直しか。
    private var replaying = false
    /// 聞き直すとき、大きな音が始まったところより何秒前から流すか。
    private static let replayLead = 0.5
    /// 文字が出ないまま、これだけ続いた認識は作り直す（秒）。
    private static let idleRestartSeconds = 20.0

    private var routeObserver: NSObjectProtocol?
    /// 受信機のマイクと本体のスピーカーを同時に使っているか。
    private var multiRoute = false
    private var restartTask: Task<Void, Never>?

    private static let logLimit = 300
    /// つないだら内蔵マイクより優先するマイク（DJI Mic などの受信機、ヘッドセット）。
    private static let externalInputs: Set<AVAudioSession.Port> = [.usbAudio, .headsetMic, .lineIn]

    /// この端末で日本語の端末内（オフライン）認識が使えるか。
    var supportsOnDevice: Bool { recognizer?.supportsOnDeviceRecognition ?? false }

    init() {
        prepareIdleRoute()
        refreshRoute()
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated { self?.routeChanged(reason) }
        }
    }

    func start() async {
        guard !isListening else { return }
        guard await requestPermissions() else { return }
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "音声認識が使えません"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            // 受信機などをつないでいれば、そちらを使う
            let external = session.availableInputs?.first { Self.externalInputs.contains($0.portType) }
            multiRoute = false
            if let external, Self.openMultiRoute(session, input: external) {
                // 受信機のマイクで聞き、効果音は本体のスピーカーから出す
                multiRoute = true
            } else {
                // .measurement は音声処理を切れるが再生音が小さくなるので、既定は .default（設定で選べる）
                try session.setCategory(.playAndRecord, mode: micMode.sessionMode, options: [.defaultToSpeaker, .mixWithOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
                try? session.setPreferredInput(external)
                if let external { Self.keepSpeaker(session, input: external) }
            }
        } catch {
            statusMessage = "マイクを開けません: \(error.localizedDescription)"
            return
        }
        refreshRoute()

        let input = engine.inputNode
        // 通話用の処理（反響を消す・音量の自動調整）は、録音の部品の側で有効にする。
        // 受信機と本体スピーカーを同時に使うとき（multiRoute）は使えないので切る
        let voiceProcessing = micMode == .voiceChat && !multiRoute
        do {
            if input.isVoiceProcessingEnabled != voiceProcessing {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            }
            if voiceProcessing {
                // 効果音など、ほかの音を小さくしすぎない
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
        } catch {
            statusMessage = "マイクの処理を切り替えられません: \(error.localizedDescription)"
        }
        input.removeTap(onBus: 0)
        Self.installTap(on: input, box: audioBox, channels: multiRoute ? Self.externalInputChannels() : nil)
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

    /// 受信機のマイクと本体のスピーカーを同時に使う形（multiRoute）で開く。
    /// 受信機をつなぐと、ふつうは音も受信機へ行って聞こえない。スピーカーへ切り替えるとマイクも内蔵に戻る。
    /// multiRoute なら両方を同時に使える。受信機のマイクか本体のスピーカーが使えなければ false。
    private static func openMultiRoute(_ session: AVAudioSession, input: AVAudioSessionPortDescription) -> Bool {
        do {
            try session.setCategory(.multiRoute, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try? session.setPreferredInput(input)
        } catch {
            return false
        }
        let route = session.currentRoute
        let ok = route.inputs.contains { externalInputs.contains($0.portType) }
            && route.outputs.contains { $0.portType == .builtInSpeaker }
        if !ok { try? session.setActive(false) }
        return ok
    }

    /// multiRoute でマイクが複数あるとき、受信機のチャンネルの位置（全マイクを並べた通し番号）。
    /// 受信機だけなら nil（そのまま使う）。
    private static func externalInputChannels() -> [Int]? {
        let inputs = AVAudioSession.sharedInstance().currentRoute.inputs
        guard inputs.count > 1 else { return nil }
        var offset = 0
        for port in inputs {
            let n = max(port.channels?.count ?? 1, 1)
            if externalInputs.contains(port.portType) { return Array(offset..<(offset + n)) }
            offset += n
        }
        return nil
    }

    /// 受信機をつなぐと効果音も受信機へ行って聞こえなくなるので、音は本体のスピーカーから出す。
    /// スピーカーへ切り替えるとマイクも内蔵に戻ることがある。そのときは音よりマイクを優先して元に戻す。
    private static func keepSpeaker(_ session: AVAudioSession, input: AVAudioSessionPortDescription) {
        try? session.overrideOutputAudioPort(.speaker)
        try? session.setPreferredInput(input)
        let usesExternal = session.currentRoute.inputs.contains { externalInputs.contains($0.portType) }
        if !usesExternal {
            try? session.overrideOutputAudioPort(.none)
            try? session.setPreferredInput(input)
        }
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
        prepareIdleRoute()
    }

    /// 聞き取っていない間も、受信機をつないでいれば効果音を本体から出せる形（multiRoute）にしておく。
    /// そのままだと iPad は音も受信機へ送るので、聞き取りを止めている間に受信機をつなぐと効果音が聞こえなくなる。
    private func prepareIdleRoute() {
        guard !isListening else { return }
        let session = AVAudioSession.sharedInstance()
        if Self.hasReceiver(session.currentRoute) {
            if session.category != .multiRoute {
                try? session.setCategory(.multiRoute, mode: .default, options: [.mixWithOthers])
            }
        } else if session.category == .multiRoute {
            try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
    }

    /// 受信機のマイクか、受信機への出力があるか（聞き取りを止めている間はマイクが見えないことがあるので、出力も見る）。
    private static func hasReceiver(_ route: AVAudioSessionRouteDescription) -> Bool {
        route.inputs.contains { externalInputs.contains($0.portType) } || route.outputs.contains { $0.portType == .usbAudio }
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
        case .redo: return "進める"
        case .nextGame: return "次のゲーム"
        case .swapEnds: return "入れ替え"
        case .resetGame: return "リセット"
        }
    }

    // MARK: - 認識

    /// - Parameter replay: 新しい認識に先に流す音声（聞き取れなかった声の聞き直し）。
    private func startRecognition(replay: [AVAudioPCMBuffer] = []) {
        guard isListening, let recognizer else { return }
        generation += 1
        let gen = generation
        currentTexts = []
        currentPartials = []
        instantFired = []
        instantSeenAt = []
        confirmTask?.cancel()
        if replay.isEmpty { audioBox.clearRecent() }
        replaying = !replay.isEmpty
        taskStartedAt = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = supportsOnDevice
        request.taskHint = taskHint
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        audioBox.setRequest(request, replay: replay)
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
            spotInstant(stable: true)
            finishUtterance(generation: gen)
            return
        }
        if instantMode {
            spotInstant(stable: false)
            confirmTask?.cancel()
            confirmTask = Task { [weak self, instantConfirm] in
                try? await Task.sleep(for: instantConfirm)
                guard !Task.isCancelled, self?.generation == gen else { return }
                self?.spotInstant(stable: true)
            }
        }
        silenceTask?.cancel()
        let wait = min(quickWait() ?? silenceInterval, silenceInterval)
        silenceTask = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.finishUtterance(generation: gen)
        }
    }

    /// 話している途中の文字から得点の言葉を探し、まだ反映していないものを反映する。
    /// - Parameter stable: 文字がしばらく変わっていない（言葉の後ろに続きが来なかった）。
    private func spotInstant(stable: Bool) {
        guard instantMode, let best = currentTexts.first else { return }
        let hits = WordSpotter.hits(tokens: ReadingConverter.hiraganaTokens(best), matcher: matcher)
            .filter { $0.status != .rejected }
        let now = Date()
        while instantSeenAt.count < hits.count { instantSeenAt.append(now) }
        // 認識が文字を書き直しても二重に入れないよう、何個目まで反映したかで数える
        for (k, hit) in hits.enumerated() where k >= instantFired.count {
            guard hit.status == .accepted || stable else { break }
            let command = VoiceCommand.point(player: hit.player)
            let accepted = gate.accept(command, at: now)
            if accepted { onCommand?(command) } else { onRejected?(command) }
            instantFired.append((command, accepted, now.timeIntervalSince(instantSeenAt[k])))
        }
    }

    /// いまの文字がそのまま操作語やスコアになっているなら、区切りを待つ時間を短くする。
    /// （「戻して」「フォーファイブ」は言い終わっているのに、無音を待つぶん遅かった）
    private func quickWait() -> Duration? {
        guard instantMode, let best = currentTexts.first else { return nil }
        if matcher.match(reading: ReadingConverter.hiragana(best)) != nil { return instantConfirm }
        if looksLikeScore(best) { return scoreConfirm }
        return nil
    }

    private func looksLikeScore(_ text: String) -> Bool {
        !ScoreCallParser.pairs(in: ReadingConverter.hiragana(text)).isEmpty || !ScoreCallParser.pairs(in: text).isEmpty
    }

    private func finishUtterance(generation gen: Int) {
        guard gen == generation else { return }
        silenceTask?.cancel()
        confirmTask?.cancel()
        let texts = currentTexts
        let partials = currentPartials
        let fired = instantFired
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
        if let first = fired.first {
            // 話している途中で反映済み。区切りでもう一度判定すると二重に入る
            let delays = fired.map { String(format: "%.2f", $0.delay) }.joined(separator: "/")
            note = "即時（出てから\(delays)秒）" + (fired.count > 1 ? " \(fired.count)件" : "")
            let audioFile = recordsAudio ? store.saveAudio(audio, at: now) : nil
            record(Utterance(
                time: now, text: best, alternatives: Array(texts.dropFirst()), partials: partials,
                reading: reading, command: first.command, accepted: first.accepted, note: note, audioFile: audioFile,
                settings: currentSettings
            ))
            return
        }
        search: for text in texts {
            for r in [ReadingConverter.hiragana(text), text] {
                if let c = matcher.match(reading: r) {
                    reading = r
                    command = c
                    break search
                }
                // 卓球の用語は記録だけして、点は動かさない。
                // スコアより先に見る（下位の候補がスコアに読めて、勝手に点が入らないように）
                if let t = matcher.term(reading: r) {
                    reading = r
                    note = "用語：" + t
                    accepted = true
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
        return (replaying ? "聞き直し " : "") + "区切り\(ms)ms 即時\(instantMode ? "ON" : "OFF") 二重防止\(gate.deadTime)秒 \(hint) マイク:\(micMode.title) 入力:\(inputName) 出力:\(outputName) 言葉 \(wordsSummary)"
    }

    // MARK: - マイクの抜き差し

    private func refreshRoute() {
        let route = AVAudioSession.sharedInstance().currentRoute
        inputName = route.inputs.map(\.portName).joined(separator: "、")
        outputName = route.outputs.map(\.portName).joined(separator: "、")
        outputIsExternal = !route.outputs.isEmpty && !route.outputs.contains { $0.portType == .builtInSpeaker }
        receiverChannels = route.inputs.first { Self.externalInputs.contains($0.portType) }?.channels?.count ?? 0
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        prepareIdleRoute()
        refreshRoute()
        // 聞き取り中にマイクを抜き差しすると録音の形式が変わって止まるので、作り直す。
        // 自分で聞き取りを止めたときの変化（.categoryChange など）では作り直さない。
        guard isListening, reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            // 抜き差しの通知はまとめて届くことがあるので、落ち着いてからやり直す
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled, self.isListening else { return }
            self.stop()
            await self.start()
        }
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
        refreshIdleTask()
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
        // 文字が出ないまま長く続いた認識は、声を聞き落としやすい（2026-11-20 の練習で、
        // はっきり言ったスコアが1分近く続けて文字にならなかった）。
        // 認識を作り直し、その音の少し前からの音声を流し直して聞き直す。
        // 前の発話より前の音は流さない（受け付け済みの言葉を二重に入れないため）。
        var seconds = now.timeIntervalSince(at) + Self.replayLead
        if let lastUtteranceAt { seconds = min(seconds, now.timeIntervalSince(lastUtteranceAt)) }
        restartRecognition(replay: audioBox.snapshotRecent(seconds: seconds))
    }

    /// 文字が出ないまま `idleRestartSeconds` 続いた認識を、静かなときに作り直す。
    private func refreshIdleTask() {
        guard isListening, currentTexts.isEmpty, audioBox.burstAt == nil, audioBox.isQuiet,
              let started = taskStartedAt, Date().timeIntervalSince(started) > Self.idleRestartSeconds else { return }
        restartRecognition(replay: [])
    }

    private func restartRecognition(replay: [AVAudioPCMBuffer]) {
        silenceTask?.cancel()
        task?.cancel()
        audioBox.request?.endAudio()
        startRecognition(replay: replay)
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

    /// `channels` を指定したら、そのチャンネルだけを受け取る（マイクが複数あるとき）。
    nonisolated private static func installTap(on node: AVAudioInputNode, box: AudioBox, channels: [Int]?) {
        var format = node.outputFormat(forBus: 0)
        if let channels, !channels.isEmpty, let unit = node.audioUnit,
           let picked = AVAudioFormat(standardFormatWithSampleRate: node.inputFormat(forBus: 0).sampleRate,
                                      channels: AVAudioChannelCount(channels.count)) {
            var map = channels.map(Int32.init)
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Input, 1,
                                              &map, UInt32(map.count * MemoryLayout<Int32>.size))
            if status == noErr { format = picked }
        }
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

    /// 認識リクエストを差し替える。`replay` を先に流してから、続きのマイクの音声を流す。
    func setRequest(_ newRequest: SFSpeechAudioBufferRecognitionRequest, replay: [AVAudioPCMBuffer]) {
        lock.lock()
        defer { lock.unlock() }
        for b in replay { newRequest.append(Self.mix(b, channel: _listenChannel)) }
        _request = newRequest
    }

    private var _listenChannel: Int?

    /// 聞き取りに使うチャンネル。nil は全部を混ぜる。手元に残す音声（録音）は全部のチャンネルのまま。
    var listenChannel: Int? {
        get { lock.lock(); defer { lock.unlock() }; return _listenChannel }
        set { lock.lock(); _listenChannel = newValue; lock.unlock() }
    }

    /// いま大きな音が続いていないか。
    var isQuiet: Bool {
        lock.lock(); defer { lock.unlock() }; return loudFrames == 0
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copy(buffer) else {
            request?.append(buffer)
            return
        }
        let listened = Self.mix(copy, channel: listenChannel)
        let level = Self.levelDB(listened)
        lock.lock()
        defer { lock.unlock() }
        // 差し替え（聞き直しの音声を流している最中）と順番が入れ替わらないよう、ロックの中で流す
        _request?.append(listened)
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

    /// 直近 `seconds` 秒ぶんの音声を、手元から消さずに返す。
    func snapshotRecent(seconds: Double) -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        var out: [AVAudioPCMBuffer] = []
        var total = 0.0
        for b in recent.reversed() {
            guard total < seconds else { break }
            out.append(b)
            total += Double(b.frameLength) / b.format.sampleRate
        }
        return out.reversed()
    }

    /// 直近の音声を、手元から消さずに写して返す。
    func snapshotRecent() -> [AVAudioPCMBuffer] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    /// 聞き取り用の1チャンネルにする。`channel` を指定したらそのチャンネルだけ、nil なら全部を平均する。
    private static func mix(_ buffer: AVAudioPCMBuffer, channel: Int?) -> AVAudioPCMBuffer {
        let count = Int(buffer.format.channelCount)
        guard count > 1, !buffer.format.isInterleaved, let src = buffer.floatChannelData,
              let mono = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate, channels: 1),
              let out = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let dst = out.floatChannelData?[0] else { return buffer }
        out.frameLength = buffer.frameLength
        let picked = channel.map { [min($0, count - 1)] } ?? Array(0..<count)
        let scale = 1 / Float(picked.count)
        for i in 0..<Int(buffer.frameLength) {
            var v: Float = 0
            for ch in picked { v += src[ch][i] }
            dst[i] = v * scale
        }
        return out
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
