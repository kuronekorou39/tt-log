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

    // 以下は 2026-11-06 の練習の音声ログで実際に出た言い方

    func testUndoWordsFromPractice() {
        for call in ["もどして", "もどす", "もとにもどす", "とりけし", "やりなおし", "ヤリナオシ"] {
            XCTAssertEqual(matcher.match(reading: call), .undo, call)
        }
    }

    func testNameWithDigitPoint() {
        // 認識は「1点」を数字で返す
        XCTAssertEqual(matcher.match(reading: "さくら1てん"), .point(player: 0))
        XCTAssertEqual(matcher.match(reading: "こう1てん"), .point(player: 1))
        XCTAssertEqual(matcher.match(reading: "コウ1てん"), .point(player: 1))
    }

    func testRepeatedWordIsOnePoint() {
        let m = VoiceCommandMatcher(playerCallNames: ["ひだり", "みぎ"])
        XCTAssertEqual(m.match(reading: "ひだりひだり"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "ひだりひだりひだり"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "みぎみぎ"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "もどしてもどして"), .undo)
        XCTAssertEqual(matcher.match(reading: "こうこう"), .point(player: 1))
        // 繰り返しでも、違う言葉が混ざれば受け付けない
        XCTAssertNil(m.match(reading: "ひだりみぎ"))
        XCTAssertNil(m.match(reading: "ひだりひだ"))
    }

    func testRepeatedNameThatIsAScoreStaysAScore() {
        // 「わんわん」は 1-1 のスコア。名前「わん」の繰り返しにはしない
        let m = VoiceCommandMatcher(playerCallNames: ["わん", "さくら"])
        XCTAssertNil(m.match(reading: "わんわん"))
        XCTAssertEqual(m.match(reading: "わん"), .point(player: 0))
    }

    func testMisheardRight() {
        let m = VoiceCommandMatcher(playerCallNames: ["ひだり", "みぎ"])
        XCTAssertEqual(m.match(reading: "ミリ"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "みりみり"), .point(player: 1))
    }

    func testSideWordsAndNamesTogether() {
        let m = VoiceCommandMatcher(playerWords: [["ひだり", "さくら"], ["みぎ", "こう"]])
        XCTAssertEqual(m.match(reading: "ひだり"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "さくら"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "さくら1てん"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "みぎ"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "こうポイント"), .point(player: 1))
        XCTAssertEqual(m.match(reading: "もどして"), .undo)
    }

    func testWordForBothPlayersIsIgnored() {
        // 相手の左右の言葉と同じ呼び名は、どちらの点か決められない
        let m = VoiceCommandMatcher(playerWords: [["ひだり", "みぎ"], ["みぎ", "こう"]])
        XCTAssertNil(m.match(reading: "みぎ"))
        XCTAssertEqual(m.match(reading: "ひだり"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "こう"), .point(player: 1))
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

    func testUndoVariants() {
        let m = VoiceCommandMatcher(playerWords: [["ひだり"], ["みぎ"]])
        for r in ["もどす", "もどして", "もどせ", "もとにもどす", "もとにもどして", "もとにもどせ", "ひとつもどして", "1つもどして", "もどせもどせ"] {
            XCTAssertEqual(m.match(reading: r), .undo, r)
        }
    }

    func testTableTennisTerms() {
        let m = VoiceCommandMatcher(playerWords: [["ひだり"], ["よし"]])
        XCTAssertEqual(m.term(reading: "デュース"), "デュース")
        XCTAssertEqual(m.term(reading: "じゅーす"), "デュース")
        XCTAssertEqual(m.term(reading: "ネット"), "ネット")
        XCTAssertEqual(m.term(reading: "ねっとねっと"), "ネット")
        // 用語は操作にしない
        XCTAssertNil(m.match(reading: "デュース"))
        // 選手の呼び名と同じ読みなら、呼び名を優先する
        XCTAssertEqual(m.match(reading: "よし"), .point(player: 1))
        XCTAssertNil(m.term(reading: "よし"))
        XCTAssertNil(m.term(reading: "ひだり"))
    }

    /// 設定の「呼び方」で選べる言葉が、スコアの言い方や操作語とぶつからないこと。
    func testCallStyleWords() {
        for word in ["ひだり", "みぎ", "あか", "しろ", "くろ"] {
            XCTAssertTrue(VoiceCommandMatcher.scoreOverlap(callName: word).isEmpty, word)
        }
        XCTAssertTrue(VoiceCommandMatcher.confusablePairs(callNames: ["ひだり", "みぎ"]).isEmpty)
        XCTAssertTrue(VoiceCommandMatcher.confusablePairs(callNames: ["あか", "しろ"]).isEmpty)
        let m = VoiceCommandMatcher(playerWords: [["あか"], ["しろ"]])
        XCTAssertEqual(m.match(reading: "あか"), .point(player: 0))
        XCTAssertEqual(m.match(reading: "しろ"), .point(player: 1))
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
