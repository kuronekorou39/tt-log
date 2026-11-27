import AVFoundation

/// 受信機（DJI Mic など）をつないでいるときの、効果音の出し先。
enum ToneOutput: String, CaseIterable, Identifiable {
    case device, receiver, both

    static let storageKey = "sound.output"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: return "本体"
        case .receiver: return "受信機"
        case .both: return "両方"
        }
    }
}

/// 操作したときの控えめな効果音。操作ごとに音を変える。
///
/// 音はその場で正弦波から作る（音源ファイルを持たない）。
/// 消音スイッチの影響を受けないように、システムサウンドではなく AVAudioEngine で鳴らす。
/// メインスレッドからだけ使う。
final class TonePlayer {
    enum Kind {
        case point, undo, redo, nextGame, gameOver, confirm, rejected
    }

    var volume: Float = 0.3
    var output = ToneOutput.device

    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    private var configObserver: NSObjectProtocol?
    /// つなぎ方が変わって、エンジンが古い出し先の情報を持っているかもしれない。
    private var stale = false

    init() {
        build()
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func play(_ kind: Kind) {
        let map = Self.channelMap(for: output)
        if stale || map != appliedMap {
            // 止めて割り当てを変えるだけだと、前のつなぎ方のまま鳴ることがあるので、エンジンごと作り直す
            build()
            applyChannelMap(map)
        }
        // 音声認識が音声の設定を切り替えると、エンジンが止まることがある。そのつど動かし直す
        if !engine.isRunning {
            engine.stop()
            do { try engine.start() } catch { stale = true; return }
        }
        player.volume = volume
        player.scheduleBuffer(buffer(for: kind), at: nil, options: .interrupts)
        // エンジンが止まると再生も止まる。isPlaying が残っていても鳴らないことがあるので毎回呼ぶ
        player.play()
    }

    private func build() {
        engine.stop()
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        appliedMap = nil
        stale = false
        // 受信機の抜き差しなどで出し先が変わった
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.stale = true }
    }

    /// 出し先のチャンネルの割り当て（いま反映しているもの）。nil はそのまま。
    private var appliedMap: [Int32]?

    /// 受信機と本体のスピーカーを同時に使っているとき（multiRoute）、選んだ出し先だけから鳴らす割り当て。
    /// 全部の出し先のチャンネルを並べ、鳴らす位置にだけ音を入れる。それ以外のつなぎ方なら nil。
    private static func channelMap(for output: ToneOutput) -> [Int32]? {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .multiRoute else { return nil }
        let outputs = session.currentRoute.outputs
        guard outputs.count > 1, outputs.contains(where: { $0.portType == .builtInSpeaker }) else { return nil }
        var map: [Int32] = []
        for port in outputs {
            let n = max(port.channels?.count ?? 1, 1)
            let on = port.portType == .builtInSpeaker ? output != .receiver : output != .device
            map += Array(repeating: on ? 0 : -1, count: n)
        }
        return map
    }

    private func applyChannelMap(_ map: [Int32]?) {
        appliedMap = map
        guard var map, let unit = engine.outputNode.audioUnit else { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 0,
                             &map, UInt32(map.count * MemoryLayout<Int32>.size))
    }

    /// (周波数 Hz, 長さ 秒) の並び。
    private func notes(for kind: Kind) -> [(Double, Double)] {
        switch kind {
        case .point: return [(1046.5, 0.07)]                 // 短く1音
        case .undo: return [(784.0, 0.06), (523.3, 0.08)]    // 下がる2音
        case .redo: return [(523.3, 0.06), (784.0, 0.08)]    // 上がる2音
        case .nextGame: return [(523.3, 0.06), (784.0, 0.06), (1046.5, 0.09)] // 上がる3音
        case .gameOver: return [(1318.5, 0.06), (1318.5, 0.06), (1046.5, 0.16)] // 高い音を2回、少し下げて長く
        case .confirm: return [(880.0, 0.04)]                // ごく短く（言ったスコアが今と同じ）
        case .rejected: return [(330.0, 0.05)]               // 低く短く（聞き取ったが受け付けなかった）
        }
    }

    private func buffer(for kind: Kind) -> AVAudioPCMBuffer {
        let rate = format.sampleRate
        let gap = 0.02
        let parts = notes(for: kind)
        let total = parts.reduce(0) { $0 + $1.1 + gap }
        let frames = AVAudioFrameCount(total * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        var i = 0
        for (freq, dur) in parts {
            let n = Int(dur * rate)
            let fade = min(Int(0.008 * rate), n / 2) // クリックノイズ防止
            for k in 0..<n where i < Int(frames) {
                var amp = 1.0
                if k < fade { amp = Double(k) / Double(fade) }
                if k > n - fade { amp = Double(n - k) / Double(fade) }
                data[i] = Float(sin(2 * .pi * freq * Double(k) / rate) * amp * 0.6)
                i += 1
            }
            let g = Int(gap * rate)
            for _ in 0..<g where i < Int(frames) {
                data[i] = 0
                i += 1
            }
        }
        while i < Int(frames) { data[i] = 0; i += 1 }
        return buf
    }
}
