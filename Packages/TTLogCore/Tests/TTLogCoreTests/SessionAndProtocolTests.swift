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

    func testUndo() {
        var log = SessionLog(config: MatchConfig(), startedAt: t0)
        XCTAssertFalse(log.undo())
        log.append(.point(winner: 0), at: at(1), source: .tap)
        XCTAssertTrue(log.undo())
        XCTAssertEqual(log.state.scores, [0, 0])
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
