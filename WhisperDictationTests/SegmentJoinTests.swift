import XCTest
@testable import WhisperDictation

final class SegmentJoinTests: XCTestCase {
    func testFirstSegmentHasNoSeparator() {
        let collector = TranscriptCollector()
        XCTAssertEqual(collector.joinAndAppend("First sentence."), "First sentence.")
        XCTAssertEqual(collector.text, "First sentence.")
    }

    func testLaterSegmentsGetLeadingSpaceInBothOutputs() {
        let collector = TranscriptCollector()
        _ = collector.joinAndAppend("First sentence.")
        XCTAssertEqual(collector.joinAndAppend("Second sentence."), " Second sentence.")
        XCTAssertEqual(collector.text, "First sentence. Second sentence.")
    }
}

final class LiveSessionDecisionTests: XCTestCase {
    func testResidualMinimumIsSampleCountBased() {
        XCTAssertFalse(DictationEngine.residualMeetsMinimum(sampleCount: 0))
        XCTAssertFalse(DictationEngine.residualMeetsMinimum(sampleCount: 4799))   // < 0.3 s
        XCTAssertTrue(DictationEngine.residualMeetsMinimum(sampleCount: 4800))    // = 0.3 s @16 kHz
    }

    func testTerminalPeriodRule() {
        XCTAssertFalse(DictationEngine.needsTerminalPeriod(committed: ""))            // empty: type nothing
        XCTAssertFalse(DictationEngine.needsTerminalPeriod(committed: "Done."))
        XCTAssertFalse(DictationEngine.needsTerminalPeriod(committed: "Really?"))
        XCTAssertTrue(DictationEngine.needsTerminalPeriod(committed: "open the file"))
    }

    func testHallucinatedOutroIsStrippedFromTheEndOnly() {
        let note = "Send the invoice tomorrow. So, thanks for watching. I'm Chris, and I'm going to talk to you soon. Bye."
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding(note),
            "Send the invoice tomorrow."
        )
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding("I'm going to talk to you soon. Bye."),
            ""
        )
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding("Lock the door. I'm going to bed."),
            "Lock the door. I'm going to bed."
        )
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding("Send it over. Bye."),
            "Send it over. Bye."
        )
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding("Take the action. And see what you got. Thanks for watching. I'll see you next time. Bye."),
            "Take the action. And see what you got."
        )
        XCTAssertEqual(
            DictationEngine.withoutHallucinatedEnding("I need to go to the shop before it closes."),
            "I need to go to the shop before it closes."
        )
    }
}
