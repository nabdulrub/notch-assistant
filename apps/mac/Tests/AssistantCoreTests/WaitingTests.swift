import Foundation
import Testing
@testable import AssistantCore

@Suite struct WaitingTests {
    let start = Date(timeIntervalSince1970: 1_000)

    @Test func theSameAcknowledgementIsNeverSaidTwiceRunning() {
        var lines = WaitingLines()
        let first = lines.acknowledgement { _ in 2 }
        let second = lines.acknowledgement { _ in 2 }
        #expect(first == WaitingLines.acknowledgements[2])
        #expect(second != first)
        #expect(WaitingLines.acknowledgements.contains(second))
    }

    @Test func stillWorkingLinesGoInOrderAndTheLastRepeats() {
        #expect(WaitingLines.stillWorking(0) == WaitingLines.stillWorking[0])
        #expect(WaitingLines.stillWorking(1) == WaitingLines.stillWorking[1])
        #expect(WaitingLines.stillWorking(9) == WaitingLines.stillWorking.last)
    }

    @Test func nothingIsSaidUntilTheUserHasWaitedAWhile() {
        let wait = HandOffWait(at: start)
        #expect(!wait.updateDue(at: start.addingTimeInterval(HandOffWait.firstUpdateAfter - 1)))
        #expect(wait.updateDue(at: start.addingTimeInterval(HandOffWait.firstUpdateAfter)))
    }

    @Test func anythingHeardStartsTheWaitAgain() {
        var wait = HandOffWait(at: start)
        wait.heard(at: start.addingTimeInterval(8))
        #expect(!wait.updateDue(at: start.addingTimeInterval(12)))
        #expect(wait.updateDue(at: start.addingTimeInterval(8 + HandOffWait.firstUpdateAfter)))
    }

    @Test func laterUpdatesComeFurtherApartAndThenStop() {
        var wait = HandOffWait(at: start)
        var now = start.addingTimeInterval(HandOffWait.firstUpdateAfter)
        wait.updated(at: now)
        #expect(!wait.updateDue(at: now.addingTimeInterval(HandOffWait.firstUpdateAfter)))
        for _ in 1..<HandOffWait.mostUpdates {
            now = now.addingTimeInterval(HandOffWait.nextUpdateAfter)
            #expect(wait.updateDue(at: now))
            wait.updated(at: now)
        }
        #expect(wait.updates == HandOffWait.mostUpdates)
        #expect(!wait.updateDue(at: now.addingTimeInterval(600)))
    }

    @Test func aVoiceThatSpeaksWordForWordTellsTheSessionNotToAcknowledge() {
        let persona = Persona.instructions(name: "Jarvis", voice: .wordForWord)
        #expect(persona.contains("Do not send an acknowledgement"))
    }
}
