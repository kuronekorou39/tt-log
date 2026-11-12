import Foundation
import XCTest
@testable import TTLogCore

final class SessionLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    func testRejectsInvalidEvents() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        XCTAssertFalse(log.append(.startNextGame, at: at(1), source: .tap))
        XCTAssertTrue(log.append(.point(winner: 0), at: at(2), source: .voice))
        XCTAssertEqual(log.events.count, 1)
    }

    func testLastScorer() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        XCTAssertNil(log.lastScorer)
        log.append(.point(winner: 1), at: at(1), source: .tap)
        log.append(.point(winner: 0), at: at(2), source: .voice)
        XCTAssertEqual(log.lastScorer, 0)
        _ = log.popLast()
        XCTAssertEqual(log.lastScorer, 1) // 戻すと、その前に点を取った側に戻る
        for _ in 0..<10 { log.append(.point(winner: 1), at: at(3), source: .tap) }
        log.append(.startNextGame, at: at(4), source: .voice)
        XCTAssertNil(log.lastScorer) // 次のゲームの始めは出さない
    }

    func testResetGame() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        XCTAssertFalse(log.append(.resetGame, at: at(1), source: .voice)) // 0-0 では何もしない
        for _ in 0..<3 { log.append(.point(winner: 0), at: at(2), source: .tap) }
        XCTAssertTrue(log.append(.resetGame, at: at(3), source: .voice))
        XCTAssertEqual(log.state.scores, [0, 0])
        XCTAssertEqual(log.state.server, 0)
        XCTAssertNil(log.lastScorer)
        XCTAssertTrue(log.games()[0].points.isEmpty)
        _ = log.popLast() // 戻すとリセット前に戻る
        XCTAssertEqual(log.state.scores, [3, 0])
    }

    func testResetFinishedGame() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        for _ in 0..<11 { log.append(.point(winner: 1), at: at(1), source: .tap) }
        XCTAssertEqual(log.state.gamesWon, [0, 1])
        XCTAssertTrue(log.append(.resetGame, at: at(2), source: .voice))
        XCTAssertEqual(log.state.phase, .playing)
        XCTAssertEqual(log.state.gamesWon, [0, 0])
        XCTAssertNil(log.games()[0].winner)
    }

    func testGamesTimeline() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        var t = 10.0
        for _ in 0..<11 { log.append(.point(winner: 1), at: at(t), source: .tap); t += 10 }
        XCTAssertFalse(log.append(.point(winner: 0), at: at(t), source: .tap)) // ゲーム終了中
        log.append(.startNextGame, at: at(200), source: .voice)
        log.append(.point(winner: 0), at: at(210), source: .voice)

        let games = log.games()
        XCTAssertEqual(games.count, 2)
        XCTAssertEqual(games[0].startedAt, t0)
        XCTAssertEqual(games[0].endedAt, at(110))
        XCTAssertEqual(games[0].winner, 1)
        XCTAssertEqual(games[0].points.count, 11)
        XCTAssertEqual(games[0].points.last?.scores, [0, 11])
        XCTAssertEqual(games[1].index, 1)
        XCTAssertEqual(games[1].startedAt, at(200))
        XCTAssertNil(games[1].endedAt)
        XCTAssertEqual(games[1].points.map(\.at), [at(210)])
    }

    func testPointsKeepServerAndSource() {
        var log = SessionLog(config: MatchConfig(firstServer: 1), startedAt: t0)
        log.append(.point(winner: 0), at: at(1), source: .voice) // サーブ 1
        log.append(.point(winner: 0), at: at(2), source: .tap)   // サーブ 1
        log.append(.point(winner: 1), at: at(3), source: .tap)   // サーブ 0
        let points = log.games()[0].points
        XCTAssertEqual(points.map(\.server), [1, 1, 0])
        XCTAssertEqual(points.map(\.source), [.voice, .tap, .tap])
    }

    func testPlayerStats() {
        var log = SessionLog(config: MatchConfig(firstServer: 0), startedAt: t0)
        // サーブ 0,0,1,1,0 の順。勝者 0,0,0,1,1
        for (i, w) in [0, 0, 0, 1, 1].enumerated() {
            log.append(.point(winner: w), at: at(Double(i)), source: .tap)
        }
        let stats = log.games().playerStats()
        XCTAssertEqual(stats[0].points, 3)
        XCTAssertEqual(stats[1].points, 2)
        XCTAssertEqual(stats[0].servePointsWon, 2)
        XCTAssertEqual(stats[0].servePointsPlayed, 3)
        XCTAssertEqual(stats[0].receivePointsWon, 1)
        XCTAssertEqual(stats[0].receivePointsPlayed, 2)
        XCTAssertEqual(stats[1].servePointsWon, 1)
        XCTAssertEqual(stats[1].servePointsPlayed, 2)
        XCTAssertEqual(stats[1].receivePointsWon, 1)
        XCTAssertEqual(stats[1].receivePointsPlayed, 3)
        XCTAssertEqual(stats[0].longestRun, 3)
        XCTAssertEqual(stats[1].longestRun, 2)
    }

    func testUndo() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        XCTAssertFalse(log.undo())
        log.append(.point(winner: 0), at: at(1), source: .tap)
        XCTAssertTrue(log.undo())
        XCTAssertEqual(log.state.scores, [0, 0])
    }

    func testRedoAfterUndo() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        log.append(.point(winner: 1), at: at(1), source: .tap)
        let undone = log.popLast()
        XCTAssertEqual(log.state.scores, [0, 0])
        XCTAssertTrue(log.redo(undone!))
        XCTAssertEqual(log.state.scores, [0, 1])
        // ゲーム中に「次のゲーム」はやり直せない
        XCTAssertFalse(log.redo(TimedEvent(event: .startNextGame, at: at(2), source: .tap)))
    }

    func testToggleServerAndSwapEnds() {
        var log = SessionLog(config: MatchConfig(firstServer: 0, firstLeft: 0), startedAt: t0)
        log.append(.point(winner: 0), at: at(1), source: .tap)
        XCTAssertEqual(log.state.server, 0)
        log.toggleServer()
        XCTAssertEqual(log.state.server, 1)
        XCTAssertEqual(log.state.scores, [1, 0], "得点は変わらない")
        XCTAssertEqual(log.state.left, 0)
        log.swapEnds()
        XCTAssertEqual(log.state.left, 1)
        // 次のゲームでも、入れ替えた設定から筋が通る
        for _ in 0..<10 { log.append(.point(winner: 0), at: at(2), source: .tap) }
        log.append(.startNextGame, at: at(3), source: .tap)
        XCTAssertEqual(log.state.server, 0)
        XCTAssertEqual(log.state.left, 0)
    }

    func testCodableRoundTrip() throws {
        var log = SessionLog(config: MatchConfig(format: .bestOf(5), firstServer: 1, firstLeft: 1), startedAt: t0)
        log.append(.point(winner: 0), at: at(1), source: .tap)
        let data = try JSONEncoder().encode(log)
        let back = try JSONDecoder().decode(SessionLog.self, from: data)
        // 日付は小数の丸めで完全一致しないことがあるので、中身ごとに比べる
        XCTAssertEqual(back.config, log.config)
        XCTAssertEqual(back.events.map(\.event), log.events.map(\.event))
        XCTAssertEqual(back.events.map(\.source), log.events.map(\.source))
        XCTAssertEqual(back.startedAt.timeIntervalSince1970, log.startedAt.timeIntervalSince1970, accuracy: 0.001)
    }
}

final class PeerProtocolTests: XCTestCase {
    func testSnapshotFromLog() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        log.append(.point(winner: 0), at: t0.addingTimeInterval(5), source: .tap)
        let s = log.snapshot(sessionId: "S1", playerNames: ["A", "B"], now: t0.addingTimeInterval(6))
        XCTAssertEqual(s.phase, .playing)
        XCTAssertTrue(s.shouldRecord)
        XCTAssertEqual(s.scores, [1, 0])
        XCTAssertEqual(s.gameStartedAt, 1_000_000)
        XCTAssertEqual(s.points, [.init(winner: 0, at: 1_005_000, scores: [1, 0])])
    }

    func testShouldRecordOnlyWhilePlaying() {
        let t0 = Date(timeIntervalSince1970: 0)
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        for i in 0..<11 { log.append(.point(winner: 0), at: t0.addingTimeInterval(Double(i)), source: .tap) }
        let s = log.snapshot(sessionId: "S1", playerNames: [], now: t0)
        XCTAssertEqual(s.phase, .gameOver)
        XCTAssertFalse(s.shouldRecord)
        XCTAssertFalse(ScoreboardSnapshot.idle(sentAt: 0).shouldRecord)
    }

    func testMessageRoundTrip() throws {
        let messages: [PeerMessage] = [
            .hello(PeerHello(role: .camera, deviceName: "cam")),
            .state(.idle(sentAt: 123)),
            .ping(sentAt: 1.5),
            .pong(pingSentAt: 1.5, receivedAt: 9.0),
        ]
        for m in messages {
            XCTAssertEqual(try PeerCodec.decode(PeerCodec.encode(m)), m)
        }
    }

    func testMessageJSONShape() throws {
        // Android 側と合わせる形。docs/protocol.md と一致させる
        let json = String(decoding: try PeerCodec.encode(.ping(sentAt: 42)), as: UTF8.self)
        XCTAssertEqual(json, #"{"sentAt":42,"type":"ping"}"#)
    }

    func testUnknownTypeFails() {
        XCTAssertThrowsError(try PeerCodec.decode(Data(#"{"type":"nope"}"#.utf8)))
    }
}

final class ClockSyncTests: XCTestCase {
    func testOffsetFromSymmetricRoundTrip() {
        var c = ClockSync()
        XCTAssertNil(c.offset)
        // 相手の時計が 500ms 進んでいる。往復 100ms
        c.add(sentAt: 1000, remoteAt: 1550, receivedAt: 1100)
        XCTAssertEqual(c.offset, 500)
        XCTAssertEqual(c.toLocal(2500), 2000)
    }

    func testPrefersShortestRoundTrip() {
        var c = ClockSync()
        c.add(sentAt: 0, remoteAt: 900, receivedAt: 1000)    // 往復 1000ms（不正確）
        c.add(sentAt: 2000, remoteAt: 2510, receivedAt: 2020) // 往復 20ms
        XCTAssertEqual(c.offset, 500)
    }

    func testIgnoresNegativeRoundTrip() {
        var c = ClockSync()
        c.add(sentAt: 100, remoteAt: 0, receivedAt: 50)
        XCTAssertNil(c.offset)
    }
}
