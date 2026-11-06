import Foundation
import XCTest
@testable import TTLogCore

// 実名は使わない。架空の呼び名で確かめる。
final class KanaNormalizerTests: XCTestCase {
    func testKatakanaBecomesHiragana() {
        XCTAssertEqual(KanaNormalizer.canonical("サクラ"), "さくら")
    }

    func testLongVowelsCollapse() {
        XCTAssertEqual(KanaNormalizer.canonical("けんた"), "けんた")
        XCTAssertEqual(KanaNormalizer.canonical("こう"), "こ")
        XCTAssertEqual(KanaNormalizer.canonical("こお"), "こ")
        XCTAssertEqual(KanaNormalizer.canonical("こー"), "こ")
        XCTAssertEqual(KanaNormalizer.canonical("コー"), "こ")
        XCTAssertEqual(KanaNormalizer.canonical("せい"), "せ")
        XCTAssertEqual(KanaNormalizer.canonical("ゲーム"), "げむ")
        XCTAssertEqual(KanaNormalizer.canonical("げえむ"), "げむ")
    }

    func testSmallKanaCarryVowel() {
        XCTAssertEqual(KanaNormalizer.canonical("きょう"), "きょ")
        XCTAssertEqual(KanaNormalizer.canonical("しゅう"), "しゅ")
    }

    func testPunctuationAndSpacesAreDropped() {
        XCTAssertEqual(KanaNormalizer.canonical(" もどして。"), "もどして")
        XCTAssertEqual(KanaNormalizer.canonical("つぎの げーむ！"), "つぎのげむ")
    }

    func testVowelNotLengtheningIsKept() {
        // 「さあ」は畳むが、「かい」の「い」は「あ」段の後なので残す
        XCTAssertEqual(KanaNormalizer.canonical("かい"), "かい")
        XCTAssertEqual(KanaNormalizer.canonical("あお"), "あお")
    }
}

final class VoiceCommandMatcherTests: XCTestCase {
    let matcher = VoiceCommandMatcher(playerCallNames: ["さくら", "こう"])

    func testPlayerNames() {
        XCTAssertEqual(matcher.match(reading: "さくら"), .point(player: 0))
        XCTAssertEqual(matcher.match(reading: "こう"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "こー"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "コウ。"), .point(player: 1))
    }

    func testNameWithPointWords() {
        for call in ["さくらてん", "さくらポイント", "さくらくん", "さくらさん", "さくらちゃん",
                     "さくらのてん", "さくらくんのポイント", "さくらいってん", "サクラ、ポイント"] {
            XCTAssertEqual(matcher.match(reading: call), .point(player: 0), call)
        }
        // 長音で終わる名前でも、付け足した形で揃う
        XCTAssertEqual(matcher.match(reading: "こうてん"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "こーくん"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "コウポイント"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "こういってん"), .point(player: 1))
    }

    func testNameThatIsANumber() {
        let m = VoiceCommandMatcher(playerCallNames: ["わん", "さくら"])
        XCTAssertEqual(m.match(reading: "ワン"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "わんぽいんと"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "わんくん"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "わんちゃん"), .point(player: 0))
        // スコア（1-10、1-3、1の10）とも読めるので、名前としては受け付けない
        XCTAssertNil(m.match(reading: "わんてん"))
        XCTAssertNil(m.match(reading: "わんさん"))
        XCTAssertNil(m.match(reading: "わんのてん"))
        // スコアの言い方はそのままスコア
        XCTAssertNil(m.match(reading: "わんらぶ"))
        XCTAssertTrue(ScoreCallParser.pairs(in: "わんらぶ").contains([1, 0]))

        let overlap = VoiceCommandMatcher.scoreOverlap(callName: "わん")
        XCTAssertNil(overlap.nameAsScore)
        XCTAssertTrue(overlap.scorePhrases.contains("わんてん"))
        XCTAssertTrue(overlap.scorePhrases.contains("わんさん"))
    }

    func testNameThatContainsANumberWord() {
        let m = VoiceCommandMatcher(playerCallNames: ["みゅうつー", "おーる"])
        XCTAssertEqual(m.match(reading: "ミュウツー"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "ミュウツーてん"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "ミュウツーさん"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "オール"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "オールさん"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "オールポイント"), .point(player: 1))
        // 数の後ろの「オール」は同点のスコア
        XCTAssertNil(m.match(reading: "スリーオール"))
        XCTAssertTrue(ScoreCallParser.pairs(in: "スリーオール").contains([3, 3]))
        XCTAssertTrue(VoiceCommandMatcher.scoreOverlap(callName: "みゅうつー").isEmpty)
        XCTAssertTrue(VoiceCommandMatcher.scoreOverlap(callName: "おーる").isEmpty)
    }

    func testNameThatIsAScore() {
        // 「いちご」は 1-5 とも読めるが、登録した名前を優先する
        let m = VoiceCommandMatcher(playerCallNames: ["いちご", "さくら"])
        XCTAssertEqual(m.match(reading: "いちご"), .point(player: 0))
        XCTAssertEqual(VoiceCommandMatcher.scoreOverlap(callName: "いちご").nameAsScore, [1, 5])
        // 「いち・ご・てん」と数が3つになりスコアではないので、名前として受け付ける
        XCTAssertEqual(m.match(reading: "いちごてん"), .point(player: 0))
    }

    func testCommands() {
        XCTAssertEqual(matcher.match(reading: "もどして"), .undo)
        XCTAssertEqual(matcher.match(reading: "つぎのげーむ"), .nextGame)
        XCTAssertEqual(matcher.match(reading: "つぎのゲーム"), .nextGame)
    }

    func testOnlyWholeUtteranceMatches() {
        XCTAssertNil(matcher.match(reading: "さくらがさ"))
        XCTAssertNil(matcher.match(reading: "いまのはさくら"))
        XCTAssertNil(matcher.match(reading: "さくらてんだった"))
        XCTAssertNil(matcher.match(reading: ""))
    }

    func testCommandWinsOverSameNamedPlayer() {
        let m = VoiceCommandMatcher(playerCallNames: ["もどして", "さくら"])
        XCTAssertEqual(m.match(reading: "もどして"), .undo)
    }

    func testConfusablePairs() {
        XCTAssertTrue(VoiceCommandMatcher.confusablePairs(callNames: ["さくら", "こう"]).isEmpty)
        // 1文字違い
        XCTAssertEqual(VoiceCommandMatcher.confusablePairs(callNames: ["さくら", "さくま"]).count, 1)
        // 長音の違いだけ
        XCTAssertEqual(VoiceCommandMatcher.confusablePairs(callNames: ["こう", "こー"]).count, 1)
        // 1文字どうしは別の音なら注意しない
        XCTAssertTrue(VoiceCommandMatcher.confusablePairs(callNames: ["こう", "け"]).isEmpty)
        // 操作語と紛らわしい
        XCTAssertEqual(VoiceCommandMatcher.confusablePairs(callNames: ["もどした", "さくら"]).count, 1)
    }
}

final class CommandGateTests: XCTestCase {
    func testSameCommandWithinDeadTimeIsRejected() {
        var gate = CommandGate(deadTime: 1.5)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(gate.accept(.point(player: 0), at: t0))
        XCTAssertFalse(gate.accept(.point(player: 0), at: t0.addingTimeInterval(1.0)))
        XCTAssertTrue(gate.accept(.point(player: 0), at: t0.addingTimeInterval(2.0)))
    }

    func testDifferentCommandIsAccepted() {
        var gate = CommandGate(deadTime: 1.5)
        let t0 = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(gate.accept(.point(player: 0), at: t0))
        XCTAssertTrue(gate.accept(.undo, at: t0.addingTimeInterval(0.5)))
        XCTAssertTrue(gate.accept(.point(player: 0), at: t0.addingTimeInterval(0.8)))
    }
}
