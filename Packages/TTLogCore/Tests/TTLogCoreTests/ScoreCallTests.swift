import Foundation
import XCTest
@testable import TTLogCore

final class ScoreCallParserTests: XCTestCase {
    private func pairs(_ s: String) -> Set<[Int]> { ScoreCallParser.pairs(in: s) }

    func testEnglishStyle() {
        XCTAssertEqual(pairs("わんらぶ"), [[1, 0]])
        XCTAssertTrue(pairs("ツーファイブ").contains([2, 5]))
        XCTAssertTrue(pairs("いれぶんないん").contains([11, 9]))
    }

    func testJapanese() {
        XCTAssertTrue(pairs("ななきゅう").contains([7, 9]))
        XCTAssertTrue(pairs("はちろく").contains([8, 6]))
        XCTAssertTrue(pairs("じゅういちじゅう").contains([11, 10]))
        XCTAssertTrue(pairs("ごたいさん").contains([5, 3]))
    }

    func testDigits() {
        XCTAssertTrue(pairs("7たい9").contains([7, 9]))
        XCTAssertTrue(pairs("7-9").contains([7, 9]))
        XCTAssertTrue(pairs("10-11").contains([10, 11]))
        XCTAssertTrue(pairs("７ ９").contains([7, 9]))
        // 「じゅうはち」を認識が「18」と返す形
        XCTAssertTrue(pairs("18").contains([10, 8]))
        XCTAssertTrue(pairs("18").contains([1, 8]))
    }

    func testOneLove() {
        for call in ["わんぜろ", "わんらぶ", "いちぜろ", "いちれい", "ワンゼロ", "1-0", "1たい0", "One love", "one zero"] {
            XCTAssertTrue(pairs(call).contains([1, 0]), call)
        }
    }

    func testThreeAll() {
        for call in ["さんさん", "すりーすりー", "スリースリー", "すりーおーる", "スリーオール", "さんすりー", "すりーさん",
                     "さんおーる", "3-3", "3たい3", "Three all", "three three"] {
            XCTAssertTrue(pairs(call).contains([3, 3]), call)
        }
    }

    func testAllAfterVowelO() {
        XCTAssertTrue(pairs("ごおーる").contains([5, 5]))
        XCTAssertTrue(pairs("ファイブオール").contains([5, 5]))
        XCTAssertTrue(pairs("ラブオール").contains([0, 0]))
        XCTAssertTrue(pairs("ぜろおーる").contains([0, 0]))
        XCTAssertTrue(pairs("フォーオール").contains([4, 4]))
        XCTAssertTrue(pairs("じゅうおーる").contains([10, 10]))
    }

    func testNotScores() {
        XCTAssertTrue(pairs("ひだり").isEmpty)
        XCTAssertTrue(pairs("もどして").isEmpty)
        XCTAssertTrue(pairs("ご").isEmpty) // 数が1つだけ
        XCTAssertTrue(pairs("いちにさんし").isEmpty) // 数が3つ以上
        XCTAssertTrue(pairs("くる").isEmpty) // 「来る」を「9オール」にしない
        XCTAssertTrue(pairs("おーる").isEmpty)
    }
}

final class ScoreCallResolverTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    /// 選手0 が a 点、選手1 が b 点の記録（1 を先に入れる）。
    private func log(_ a: Int, _ b: Int, firstServer: Int = 0) -> SessionLog {
        var l = SessionLog(config: MatchConfig(firstServer: firstServer), startedAt: t0)
        for _ in 0..<b { l.append(.point(winner: 1), at: t0, source: .tap) }
        for _ in 0..<a { l.append(.point(winner: 0), at: t0, source: .tap) }
        return l
    }

    private func resolve(_ said: [Int], _ l: SessionLog) -> ScoreCallResolver.Resolution? {
        ScoreCallResolver.resolve(pairs: [said], log: l)
    }

    func testTeenDigitsAsTen() {
        // 2026-11-12 の練習：9-8 で「じゅうはち」→「18」、8-10 で「じゅうく」→「19」
        XCTAssertEqual(ScoreCallResolver.resolve(pairs: ScoreCallParser.pairs(in: "18"), log: log(9, 8)), .points(player: 0, count: 1))
        XCTAssertEqual(ScoreCallResolver.resolve(pairs: ScoreCallParser.pairs(in: "19"), log: log(8, 10)), .points(player: 0, count: 1))
        // 1-8 のつもりのときは今まで通り
        XCTAssertEqual(ScoreCallResolver.resolve(pairs: ScoreCallParser.pairs(in: "18"), log: log(1, 7)), .points(player: 1, count: 1))
    }

    func testEitherOrderIsAccepted() {
        // 1-2 のときに「3-1」→ 1-3（選手1 に1点）
        XCTAssertEqual(resolve([3, 1], log(1, 2)), .points(player: 1, count: 1))
        XCTAssertEqual(resolve([1, 3], log(1, 2)), .points(player: 1, count: 1))
        // 8-6 のときに「9-6」でも「6-9」でも 9-6
        XCTAssertEqual(resolve([9, 6], log(8, 6)), .points(player: 0, count: 1))
        XCTAssertEqual(resolve([6, 9], log(8, 6)), .points(player: 0, count: 1))
    }

    func testConfirmAndUndo() {
        XCTAssertEqual(resolve([2, 1], log(1, 2)), .confirm)
        // 直前は選手0 の点（1 を先に入れているので）。1つ前のスコア 0-2 を言えば取り消し
        XCTAssertEqual(resolve([0, 2], log(1, 2)), .undo)
        XCTAssertEqual(resolve([2, 0], log(1, 2)), .undo)
    }

    func testCatchUpMissedPoints() {
        XCTAssertEqual(resolve([5, 2], log(3, 2)), .points(player: 0, count: 2))
        XCTAssertNil(resolve([9, 2], log(3, 2)), "4点以上の追いかけは受け付けない")
        XCTAssertNil(resolve([5, 5], log(3, 2)), "両方が進んでいる形は受け付けない")
    }

    func testTieUsesServerFirst() {
        let l = log(3, 3, firstServer: 0)
        let server = l.state.server!
        // 同点では順番から決まらないので、先に言った数（4）をサーブの人の点とみなす
        XCTAssertEqual(resolve([4, 3], l), .points(player: server, count: 1))
        XCTAssertEqual(resolve([3, 4], l), .points(player: 1 - server, count: 1))
    }

    func testLoveAllTieBreak() {
        // 0-0 で「ワンラブ」：同点なのでサーブの人の点とみなす
        let l = SessionLog(config: MatchConfig(firstServer: 1), startedAt: t0)
        XCTAssertEqual(resolve([1, 0], l), .points(player: 1, count: 1))
    }

    func testCannotSkipPastGameEnd() {
        // 9-5 から「12-5」は途中の 11-5 でゲームが終わるので筋が通らない
        XCTAssertNil(resolve([12, 5], log(9, 5)))
        // 10-5 から「11-5」は受け付ける（最後の1点でゲームが終わるのはよい）
        XCTAssertEqual(resolve([11, 5], log(10, 5)), .points(player: 0, count: 1))
    }

    func testGameOverOnlyConfirmOrUndo() {
        let l = log(11, 5)
        XCTAssertEqual(resolve([11, 5], l), .confirm)
        XCTAssertEqual(resolve([10, 5], l), .undo)
        XCTAssertNil(resolve([11, 6], l))
    }

    func testMultipleParsesNarrowDown() {
        // 「じゅういちじゅう」は 11-10 と読めるが、10-10 のときは 11-10 しか筋が通らない
        var l = SessionLog(config: MatchConfig(), startedAt: t0)
        for _ in 0..<10 { l.append(.point(winner: 0), at: t0, source: .tap); l.append(.point(winner: 1), at: t0, source: .tap) }
        let p = ScoreCallParser.pairs(in: "じゅういちじゅう")
        let r = ScoreCallResolver.resolve(pairs: p, log: l)
        // 10-10 は同点。サーブの人の点を先に言ったとみなす
        let server = l.state.server!
        XCTAssertEqual(r, .points(player: server, count: 1))
    }
}
