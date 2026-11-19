import Foundation
import Testing
@testable import AssistantCore

@Suite struct QuietTests {
    private let rule = QuietRule(idle: 15)
    private let start = Date(timeIntervalSince1970: 1000)

    @Test func silenceClosesTheLine() {
        #expect(!rule.isOver(at: start.addingTimeInterval(14), lastEngaged: start, lastUserSound: start))
        #expect(rule.isOver(at: start.addingTimeInterval(16), lastEngaged: start, lastUserSound: start))
    }

    @Test func someoneStillTalkingKeepsItOpen() {
        let now = start.addingTimeInterval(45)
        #expect(!rule.isOver(at: now, lastEngaged: start, lastUserSound: now))
    }

    @Test func theCountStartsWhenTheyStopTalking() {
        let stopped = start.addingTimeInterval(40)
        #expect(!rule.isOver(at: stopped.addingTimeInterval(14), lastEngaged: start, lastUserSound: stopped))
        #expect(rule.isOver(at: stopped.addingTimeInterval(16), lastEngaged: start, lastUserSound: stopped))
    }

    @Test func theCountStartsWhenTheAssistantStopsTalking() {
        let spokeUntil = start.addingTimeInterval(30)
        #expect(!rule.isOver(at: spokeUntil.addingTimeInterval(14), lastEngaged: spokeUntil, lastUserSound: start))
        #expect(rule.isOver(at: spokeUntil.addingTimeInterval(16), lastEngaged: spokeUntil, lastUserSound: start))
    }

    @Test func aRoomThatNeverStopsTalkingDoesNotHoldItOpen() {
        let now = start.addingTimeInterval(15 + QuietRule.longestTalk + 1)
        #expect(rule.isOver(at: now, lastEngaged: start, lastUserSound: now))
    }

    @Test func aLongRequestAfterTheNameIsHeardOut() {
        let now = start.addingTimeInterval(30)
        #expect(!NameRequest.isTaken(at: now, nameHeardAt: start, lastNewWords: now.addingTimeInterval(-1)))
        #expect(NameRequest.isTaken(at: now, nameHeardAt: start, lastNewWords: now.addingTimeInterval(-4)))
    }

    @Test func aShortRequestIsNotTakenEarly() {
        #expect(!NameRequest.isTaken(at: start.addingTimeInterval(8), nameHeardAt: start, lastNewWords: start))
    }

    @Test func aRequestThatNeverEndsIsTakenAsItStands() {
        let now = start.addingTimeInterval(61)
        #expect(NameRequest.isTaken(at: now, nameHeardAt: start, lastNewWords: now))
    }
}
