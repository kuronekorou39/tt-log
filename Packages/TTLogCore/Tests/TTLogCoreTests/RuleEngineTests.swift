import XCTest
@testable import TTLogCore

final class RuleEngineTests: XCTestCase {
    /// 選手0 が a 点、選手1 が b 点取った操作列。
    /// 選手1 の点を先に入れる（0 を先にまとめると、11-9 のつもりが 11-0 で決着してしまうため）。
    /// 選手1 が勝つ試合は points(0, 11) のように 0 側を0点にして使う。
    private func points(_ a: Int, _ b: Int) -> [MatchEvent] {
        Array(repeating: .point(winner: 1), count: b) + Array(repeating: .point(winner: 0), count: a)
    }

    /// デュースにしてから決着をつける（10-10 → 交互に取り合い → 最後に winner が2連取）。
    private func deuceGame(winner: Int, extraPairs: Int = 0) -> [MatchEvent] {
        var e: [MatchEvent] = []
        for _ in 0..<10 { e += [.point(winner: 0), .point(winner: 1)] }
        for _ in 0..<extraPairs { e += [.point(winner: 0), .point(winner: 1)] }
        e += [.point(winner: winner), .point(winner: winner)]
        return e
    }

    // MARK: - サーブ

    func testServeChangesEveryTwoPoints() {
        let c = MatchConfig(firstServer: 0)
        XCTAssertEqual(RuleEngine.reduce(c, []).server, 0)
        XCTAssertEqual(RuleEngine.reduce(c, points(1, 0)).server, 0)
        XCTAssertEqual(RuleEngine.reduce(c, points(1, 1)).server, 1)
        XCTAssertEqual(RuleEngine.reduce(c, points(2, 1)).server, 1)
        XCTAssertEqual(RuleEngine.reduce(c, points(2, 2)).server, 0)
        XCTAssertEqual(RuleEngine.reduce(c, points(9, 9)).server, 1)
    }

    func testServeChangesEveryPointFromDeuce() {
        let c = MatchConfig(firstServer: 0)
        var e: [MatchEvent] = []
        for _ in 0..<10 { e += [.point(winner: 0), .point(winner: 1)] }
        XCTAssertEqual(RuleEngine.reduce(c, e).scores, [10, 10])
        XCTAssertEqual(RuleEngine.reduce(c, e).server, 0)
        e.append(.point(winner: 0)) // 11-10
        XCTAssertEqual(RuleEngine.reduce(c, e).server, 1)
        e.append(.point(winner: 1)) // 11-11
        XCTAssertEqual(RuleEngine.reduce(c, e).server, 0)
    }

    func testFirstServerAlternatesEachGame() {
        let c = MatchConfig(firstServer: 1)
        let e = points(11, 0) + [.startNextGame]
        XCTAssertEqual(RuleEngine.reduce(c, e).server, 0)
        let e2 = e + points(11, 0) + [.startNextGame]
        XCTAssertEqual(RuleEngine.reduce(c, e2).server, 1)
    }

    // MARK: - ゲームの決着

    func testGameEndsAtElevenWithTwoPointLead() {
        let c = MatchConfig()
        let s = RuleEngine.reduce(c, points(11, 9))
        XCTAssertEqual(s.phase, .gameOver(winner: 0))
        XCTAssertEqual(s.scores, [11, 9])
        XCTAssertNil(s.server)
    }

    func testNoWinWithOnePointLead() {
        let c = MatchConfig()
        var e: [MatchEvent] = []
        for _ in 0..<10 { e += [.point(winner: 0), .point(winner: 1)] }
        e.append(.point(winner: 1)) // 10-11
        XCTAssertEqual(RuleEngine.reduce(c, e).phase, .playing)
        e.append(.point(winner: 1)) // 10-12
        XCTAssertEqual(RuleEngine.reduce(c, e).phase, .gameOver(winner: 1))
    }

    func testLongDeuce() {
        let s = RuleEngine.reduce(MatchConfig(), deuceGame(winner: 0, extraPairs: 5))
        XCTAssertEqual(s.scores, [17, 15])
        XCTAssertEqual(s.phase, .gameOver(winner: 0))
    }

    // MARK: - 連続形式

    func testPointsIgnoredUntilNextGameStarts() {
        let c = MatchConfig()
        let s = RuleEngine.reduce(c, points(11, 3) + [.point(winner: 1)])
        XCTAssertEqual(s.scores, [11, 3])
        XCTAssertNil(RuleEngine.apply(.point(winner: 1), to: s, config: c))
    }

    func testNextGameIgnoredDuringPlay() {
        let c = MatchConfig()
        let s = RuleEngine.reduce(c, points(3, 2))
        XCTAssertNil(RuleEngine.apply(.startNextGame, to: s, config: c))
    }

    func testContinuousNeverEnds() {
        let c = MatchConfig(format: .continuous)
        var e: [MatchEvent] = []
        for _ in 0..<6 { e += points(11, 0) + [.startNextGame] }
        let s = RuleEngine.reduce(c, e)
        XCTAssertEqual(s.phase, .playing)
        XCTAssertEqual(s.gameIndex, 6)
        XCTAssertEqual(s.gamesWon, [6, 0])
    }

    // MARK: - エンド

    func testEndsSwapEachGame() {
        let c = MatchConfig(firstLeft: 1)
        XCTAssertEqual(RuleEngine.reduce(c, []).left, 1)
        // ゲーム終了中はまだ入れ替えない（次のゲームを始めたときに入れ替える）
        XCTAssertEqual(RuleEngine.reduce(c, points(11, 0)).left, 1)
        XCTAssertEqual(RuleEngine.reduce(c, points(11, 0) + [.startNextGame]).left, 0)
        XCTAssertEqual(RuleEngine.reduce(c, points(11, 0) + [.startNextGame] + points(0, 11) + [.startNextGame]).left, 1)
    }

    func testDecidingGameSwapsEndsAtFive() {
        let c = MatchConfig(format: .bestOf(3), firstLeft: 0)
        // 1-1 にして第3ゲーム（最終ゲーム）へ
        let toDecider = points(11, 0) + [.startNextGame] + points(0, 11) + [.startNextGame]
        let start = RuleEngine.reduce(c, toDecider)
        XCTAssertEqual(start.gameIndex, 2)
        XCTAssertEqual(start.left, 0)

        let at4 = RuleEngine.reduce(c, toDecider + points(4, 3))
        XCTAssertEqual(at4.left, 0)
        XCTAssertFalse(at4.switchedEndsMidGame)

        let at5 = RuleEngine.reduce(c, toDecider + points(4, 3) + [.point(winner: 1), .point(winner: 1)]) // 4-5
        XCTAssertEqual(at5.left, 1)
        XCTAssertTrue(at5.switchedEndsMidGame)

        // 相手が後から5点に達しても、もう入れ替えない
        let later = RuleEngine.reduce(c, toDecider + points(4, 3) + [.point(winner: 1), .point(winner: 1), .point(winner: 0)])
        XCTAssertEqual(later.left, 1)
    }

    func testNoMidGameSwapInContinuous() {
        let s = RuleEngine.reduce(MatchConfig(format: .continuous), points(5, 0))
        XCTAssertFalse(s.switchedEndsMidGame)
        XCTAssertEqual(s.left, 0)
    }

    // MARK: - ゲームマッチ

    func testBestOfThreeEndsAtTwoWins() {
        let c = MatchConfig(format: .bestOf(3))
        let e = points(11, 0) + [.startNextGame] + points(11, 5)
        let s = RuleEngine.reduce(c, e)
        XCTAssertEqual(s.phase, .matchOver(winner: 0))
        XCTAssertEqual(s.gamesWon, [2, 0])
        XCTAssertNil(RuleEngine.apply(.startNextGame, to: s, config: c))
    }

    func testBestOfFiveNeedsThree() {
        let c = MatchConfig(format: .bestOf(5))
        let e = points(11, 0) + [.startNextGame] + points(11, 0) + [.startNextGame] + points(0, 11)
        XCTAssertEqual(RuleEngine.reduce(c, e).phase, .gameOver(winner: 1))
        let e2 = e + [.startNextGame] + points(11, 0)
        XCTAssertEqual(RuleEngine.reduce(c, e2).phase, .matchOver(winner: 0))
    }

    // MARK: - 取り消し

    func testUndoIsDroppingLastEvent() {
        let c = MatchConfig()
        let e = points(11, 4) + [.startNextGame, .point(winner: 1)]
        let undone = RuleEngine.reduce(c, Array(e.dropLast()))
        XCTAssertEqual(undone.scores, [0, 0])
        XCTAssertEqual(undone.gameIndex, 1)
        // 「次のゲーム」も取り消せる
        let undone2 = RuleEngine.reduce(c, Array(e.dropLast(2)))
        XCTAssertEqual(undone2.phase, .gameOver(winner: 0))
        XCTAssertEqual(undone2.scores, [11, 4])
    }

    func testInvalidEventsAreSkipped() {
        let c = MatchConfig()
        let s = RuleEngine.reduce(c, [.startNextGame, .point(winner: 2), .point(winner: 0)])
        XCTAssertEqual(s.scores, [1, 0])
    }
}
