import Foundation
import Testing
@testable import AssistantCore

@Suite struct ResumptionTests {
    private let line = "Okay so gift cards passed review. There's one small fix going in first. Then the pull request opens."

    @Test func picksUpFromTheSentenceTheCutFellIn() {
        #expect(Resumption.rest(of: line, heardWords: 8) == "There's one small fix going in first. Then the pull request opens.")
    }

    @Test func cutInTheFirstSentenceSaysItAllAgain() {
        #expect(Resumption.rest(of: line, heardWords: 3) == line)
        #expect(Resumption.rest(of: line, heardWords: 0) == line)
    }

    @Test func aSentenceJustFinishedIsNotSaidAgain() {
        #expect(Resumption.rest(of: line, heardWords: 6) == "There's one small fix going in first. Then the pull request opens.")
    }

    @Test func nothingIsLeftOfALineThatWasAllButDone() {
        #expect(Resumption.rest(of: line, heardWords: 17).isEmpty)
        #expect(Resumption.rest(of: line, heardWords: 40).isEmpty)
        #expect(Resumption.rest(of: "", heardWords: 0).isEmpty)
    }

    @Test func aTimeOrAHesitationDoesNotEndASentence() {
        let text = "It runs at 3.30 PM, so... yeah, not yet. Want me to move it?"
        #expect(Resumption.sentences(in: text).count == 2)
        #expect(Resumption.rest(of: text, heardWords: 5) == text)
    }

    @Test func wordsHeardIsGuessedLow() {
        #expect(Resumption.wordsHeard(after: 2, wordsPerSecond: 3) == 4)
        #expect(Resumption.wordsHeard(after: 0, wordsPerSecond: 3) == 0)
    }

    @Test func theVoicePickingItUpItselfIsRecognised() {
        #expect(Resumption.isSameLine(" Then the pull request opens.", held: line))
        #expect(Resumption.isSameLine(line, held: "Then the pull request opens."))
        #expect(!Resumption.isSameLine("Yeah? What's up?", held: line))
        #expect(!Resumption.isSameLine("Then", held: line))
    }

    @Test func aHeldLineWaitsForARequestThenForQuiet() {
        let cut = Date(timeIntervalSince1970: 1000)
        let held = HeldLine(text: line, cutAt: cut)
        #expect(!held.due(at: cut.addingTimeInterval(1), lastSound: cut.addingTimeInterval(-9), busy: false))
        #expect(held.due(at: cut.addingTimeInterval(5), lastSound: cut.addingTimeInterval(0.5), busy: false))
        #expect(!held.due(at: cut.addingTimeInterval(5), lastSound: cut.addingTimeInterval(3), busy: false))
        #expect(!held.due(at: cut.addingTimeInterval(6), lastSound: cut, busy: true))
    }

    @Test func aRoomThatNeverGoesQuietDoesNotHoldItForever() {
        let cut = Date(timeIntervalSince1970: 1000)
        let held = HeldLine(text: line, cutAt: cut)
        #expect(held.due(at: cut.addingTimeInterval(10), lastSound: cut.addingTimeInterval(10), busy: true))
    }

    @Test func aLineHeardAfterAllIsNoLongerMarkedCutOff() {
        var dialogue = Dialogue()
        dialogue.append(.voice, "Gift cards passed review.")
        dialogue.markCutOff()
        #expect(dialogue.lines[0].cutOff)
        dialogue.heardAfterAll(0)
        #expect(!dialogue.lines[0].cutOff)
        dialogue.heardAfterAll(7)
    }

    @Test func theVoicesOwnWordForHowFarItGotIsUsed() {
        let rest = Resumption.rest(of: line, heard: "Okay so gift cards passed review. There's")
        #expect(rest == "There's one small fix going in first. Then the pull request opens.")
        #expect(Resumption.rest(of: line, heard: "Okay so gift") == line)
        #expect(Resumption.rest(of: line, heard: line) == "")
    }

    @Test func somethingElseHavingBeenSpokenIsNotThisLine() {
        #expect(Resumption.rest(of: line, heard: "Yeah, one sec.") == nil)
        #expect(Resumption.rest(of: line, heard: "") == nil)
    }
}
