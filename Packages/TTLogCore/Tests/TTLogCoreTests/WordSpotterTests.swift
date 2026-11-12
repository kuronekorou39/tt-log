import XCTest
@testable import TTLogCore

/// 例は 2026-11-12 の練習の音声ログから。単語の区切りはアプリ側（CFStringTokenizer）の区切り方に合わせる。
final class WordSpotterTests: XCTestCase {
    private let matcher = VoiceCommandMatcher(playerWords: [["ひだり", "ろう"], ["みぎ", "とも"]])

    private func hits(_ tokens: [String]) -> [WordSpotter.Hit] {
        WordSpotter.hits(tokens: tokens, matcher: matcher)
    }

    func testWordAloneIsPending() {
        XCTAssertEqual(hits(["ひだり"]), [.init(player: 0, tokenIndex: 0, status: .pending)])
    }

    func testWordAfterTalkIsFound() {
        // 「できたら左」：言葉の前の会話は気にしない
        XCTAssertEqual(hits(["でき", "たら", "ひだり"]).map(\.status), [.pending])
    }

    func testAttachedContinuationIsRejected() {
        XCTAssertEqual(hits(["みぎ", "に", "いく"]).map(\.status), [.rejected]) // 右に行く
        XCTAssertEqual(hits(["みぎ", "おく"]).map(\.status), [.rejected]) // 右奥
        XCTAssertEqual(hits(["ほんとう", "は", "ひだり", "を"]).map(\.status), [.rejected])
    }

    func testLaughAndCheersAfterWordAreAccepted() {
        XCTAssertEqual(hits(["ひだり", "ははは"]).map(\.status), [.accepted])
        XCTAssertEqual(hits(["みぎ", "よし"]).map(\.status), [.accepted])
        XCTAssertEqual(hits(["みぎ", "やばい"]).map(\.status), [.accepted])
        XCTAssertEqual(hits(["ひだり", "ないす"]).map(\.status), [.accepted])
    }

    func testTwoWordsInOneBreath() {
        XCTAssertEqual(hits(["ひだり", "みぎ"]), [
            .init(player: 0, tokenIndex: 0, status: .accepted),
            .init(player: 1, tokenIndex: 1, status: .pending),
        ])
    }

    func testPointWordsAcrossTokens() {
        // 「左点」→「ひだり」「てん」は1つの言葉
        XCTAssertEqual(hits(["ひだり", "てん"]), [.init(player: 0, tokenIndex: 0, status: .pending)])
        XCTAssertEqual(hits(["とも", "くん", "の", "ぽいんと"]).map(\.player), [1])
    }

    func testWordInsideAnotherWordIsIgnored() {
        // 「君嫌い」の「みぎ」は単語をまたぐので拾わない
        XCTAssertTrue(hits(["きみ", "きらい"]).isEmpty)
    }

    func testMisheardAndNames() {
        XCTAssertEqual(hits(["ひだ"]).map(\.player), [0]) // 飛騨
        XCTAssertEqual(hits(["ろう"]).map(\.player), [0])
    }
}
