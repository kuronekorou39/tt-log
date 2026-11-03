import AVFoundation

/// 操作したときの控えめな効果音。操作ごとに音を変える。
///
/// 音はその場で正弦波から作る（音源ファイルを持たない）。
/// 消音スイッチの影響を受けないように、システムサウンドではなく AVAudioEngine で鳴らす。
/// メインスレッドからだけ使う。
final class TonePlayer {
    enum Kind {
        case point, undo, nextGame, gameOver, rejected
    }

    var volume: Float = 0.3

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func play(_ kind: Kind) {
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.volume = volume
        player.scheduleBuffer(buffer(for: kind), at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
    }

    /// (周波数 Hz, 長さ 秒) の並び。
    private func notes(for kind: Kind) -> [(Double, Double)] {
        switch kind {
        case .point: return [(1046.5, 0.07)]                 // 短く1音
        case .undo: return [(784.0, 0.06), (523.3, 0.08)]    // 下がる2音
        case .nextGame: return [(523.3, 0.06), (784.0, 0.06), (1046.5, 0.09)] // 上がる3音
        case .gameOver: return [(1318.5, 0.06), (1318.5, 0.06), (1046.5, 0.16)] // 高い音を2回、少し下げて長く
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
