import Foundation
import SwiftData
import SwiftUI
import TTLogCore

/// README のキャプチャ用の見本の画面。起動引数 `-demo <画面>` のときだけ使う。
/// データはメモリ上だけに置くので、端末の記録には触れない。
enum DemoScreen: String {
    case playing, gameWon, result, deviceLog

    static var current: DemoScreen? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-demo"), i + 1 < args.count else { return nil }
        return DemoScreen(rawValue: args[i + 1])
    }
}

struct DemoView: View {
    let screen: DemoScreen

    @Query(sort: \SessionRecord.startedAt) private var sessions: [SessionRecord]

    var body: some View {
        switch screen {
        case .playing, .gameWon:
            ScoreboardView(onChangeRole: {})
        case .result:
            NavigationStack {
                if let session = sessions.first {
                    SessionDetailView(session: session)
                }
            }
        case .deviceLog:
            NavigationStack {
                ScrollView {
                    DeviceLogChart(samples: Demo.deviceSamples()).padding()
                }
                .navigationTitle("温度・電池の記録")
            }
        }
    }
}

enum Demo {
    @MainActor
    static func makeContainer(_ screen: DemoScreen) -> ModelContainer {
        let container = try! ModelContainer(for: PlayerRecord.self, SessionRecord.self,
                                            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let players = [PlayerRecord(name: "あおい", callName: "あおい"),
                       PlayerRecord(name: "ひなた", callName: "ひなた")]
        players.forEach { context.insert($0) }
        switch screen {
        case .playing: insertSession(players, games: [[11, 7], [9, 11], [8, 6]], ended: false, into: context)
        case .gameWon: insertSession(players, games: [[11, 7], [9, 11]], ended: false, into: context)
        case .result: insertSession(players, games: [[11, 7], [9, 11], [11, 5], [11, 8]], ended: true, into: context)
        case .deviceLog: break
        }
        try? context.save()
        return container
    }

    private static func insertSession(_ players: [PlayerRecord], games: [[Int]], ended: Bool, into context: ModelContext) {
        let start = Date().addingTimeInterval(-Double(games.count) * 600)
        var log = SessionLog(config: MatchConfig(format: .bestOf(5)), startedAt: start)
        var t = start
        for (g, target) in games.enumerated() {
            if g > 0 {
                t += 90
                _ = log.append(.startNextGame, at: t, source: .voice)
            }
            for (i, winner) in pointOrder(target, seed: g).enumerated() {
                t += 15 + Double((g * 7 + i * 13) % 25)
                _ = log.append(.point(winner: winner), at: t, source: i % 6 == 5 ? .tap : .voice)
            }
        }
        let record = SessionRecord(players: players, log: log)
        if ended { record.endedAt = t + 30 }
        context.insert(record)
    }

    /// 得点の順番。決着したゲームは最後の1点を勝った側にして、途中で終わらないようにする。
    private static func pointOrder(_ target: [Int], seed: Int) -> [Int] {
        var left = target
        let winner: Int? = max(target[0], target[1]) >= 11 ? (target[0] > target[1] ? 0 : 1) : nil
        if let winner { left[winner] -= 1 }
        var rng = UInt64(seed + 1) &* 0x9E37_79B9_7F4A_7C15
        var order: [Int] = []
        while left[0] + left[1] > 0 {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let p = Int((rng >> 33) % UInt64(left[0] + left[1])) < left[0] ? 0 : 1
            left[p] -= 1
            order.append(p)
        }
        if let winner { order.append(winner) }
        return order
    }

    /// 90分の練習で、ゲームごとに録画した日の温度・電池の見本。
    static func deviceSamples() -> [DeviceSample] {
        let start = Date().addingTimeInterval(-90 * 60)
        let recordingMinutes = [5...14, 18...28, 32...40, 45...56, 60...71]
        return (0..<(90 * 6)).map { i in
            let minute = i / 6
            let recording = recordingMinutes.contains { $0.contains(minute) }
            let thermal = minute < 20 ? 0 : (recording && minute >= 60 ? 2 : 1)
            return DeviceSample(at: start.addingTimeInterval(Double(i) * 10),
                                thermal: thermal,
                                battery: 100 - minute * 30 / 90,
                                charging: false,
                                freeBytes: Int64(40_000 - minute * 90) * 1_000_000,
                                recording: recording)
        }
    }
}
