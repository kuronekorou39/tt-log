import Foundation
import SwiftData
import TTLogCore

/// 登録した選手。記録は ID でつながるので、名前を変えても過去の記録はそのまま。
@Model
final class PlayerRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    /// 音声で呼ぶ名前の読み（ひらがな）。画面の左右の言葉と一緒に受け付ける。
    var callName: String
    /// 記録が残っている選手は消さずに隠す。
    var isHidden: Bool
    var createdAt: Date

    init(name: String, callName: String) {
        id = UUID()
        self.name = name
        self.callName = callName
        isHidden = false
        createdAt = Date()
    }
}

/// 1回の記録（連続形式なら1日の練習、ゲームマッチなら1試合）。
@Model
final class SessionRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var playerIDs: [UUID]
    /// 記録した時点の名前（選手を消したり名前を変えたりしても、履歴の表示が変わらないように）。
    var playerNames: [String]
    /// 操作の列（`SessionLog` を JSON にしたもの）。状態は保存せず、ここから導く。
    var logData: Data

    init(players: [PlayerRecord], log: SessionLog) {
        id = UUID()
        startedAt = log.startedAt
        endedAt = nil
        playerIDs = players.map(\.id)
        playerNames = players.map(\.name)
        logData = (try? JSONEncoder().encode(log)) ?? Data()
    }

    var log: SessionLog {
        get {
            (try? JSONDecoder().decode(SessionLog.self, from: logData))
                ?? SessionLog(config: MatchConfig(), startedAt: startedAt)
        }
        set {
            logData = (try? JSONEncoder().encode(newValue)) ?? logData
        }
    }
}

extension MatchFormat {
    var title: String {
        switch self {
        case .continuous: return "1ゲームずつ続ける"
        case .bestOf(let n): return "\(n)ゲームマッチ"
        }
    }
}

extension SessionLog {
    /// 履歴や共有に使う1行の要約。例「3 - 2（11-7, 9-11, …）」
    func summary(names: [String]) -> String {
        let games = self.games().filter { $0.winner != nil }
        let won = [0, 1].map { p in games.filter { $0.winner == p }.count }
        let scores = games.compactMap { $0.points.last?.scores }.map { "\($0[0])-\($0[1])" }
        let a = names.first ?? "A"
        let b = names.count > 1 ? names[1] : "B"
        return "\(a) \(won[0]) - \(won[1]) \(b)" + (scores.isEmpty ? "" : "（\(scores.joined(separator: ", "))）")
    }
}
