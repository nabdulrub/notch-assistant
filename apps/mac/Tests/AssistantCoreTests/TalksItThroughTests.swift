import Foundation
import Testing
@testable import AssistantCore

@Suite struct TalksItThroughTests {
    private func prompt(_ change: (inout AssistantSettings) -> Void = { _ in }) -> String {
        var settings = AssistantSettings(assistantName: "Jarvis")
        change(&settings)
        return Persona.instructions(for: settings)
    }

    @Test func itAsksBeforeItStartsWorkUnlessToldNotTo() {
        let asked = prompt()
        #expect(asked.contains("Before you start work, talk it through:"))
        #expect(asked.contains("Never fill a gap yourself."))
        #expect(asked.contains("One question per reply"))
    }

    @Test func lookingSomethingUpNeedsNoQuestions() {
        #expect(prompt().contains("Finding something out is not work"))
    }

    @Test func beingToldToJustGoStopsTheQuestions() {
        #expect(prompt().contains("means stop asking"))
    }

    @Test func switchedOffItStartsAtOnceAndSaysWhatItAssumed() {
        let direct = prompt { $0.delegation.talksItThrough = false }
        #expect(!direct.contains("Before you start work, talk it through:"))
        #expect(direct.contains("Start at once from what they said."))
        #expect(direct.contains("say what you picked in one line"))
    }

    @Test func eitherWayItDoesNotAddConditionsOfItsOwn() {
        #expect(prompt().contains("Anything you added is marked in the brief as your suggestion"))
        #expect(prompt().contains("goes in their words, with nothing added"))
        #expect(prompt { $0.delegation.talksItThrough = false }.contains("Do not add conditions of your own"))
    }

    @Test func aSummaryFromTheVoiceOnThisMacIsNotEnoughToBuildFrom() {
        let onDevice = prompt { $0.voiceEngine = "sophon" }
        #expect(onDevice.contains("ask for the detail again instead of working from the summary"))
    }

    @Test func theSettingSurvivesTheTripToDiskAndDefaultsToOn() throws {
        var delegation = Delegation()
        #expect(delegation.talksItThrough)
        delegation.talksItThrough = false
        let back = try JSONDecoder().decode(Delegation.self, from: JSONEncoder().encode(delegation))
        #expect(!back.talksItThrough)
        let old = try JSONDecoder().decode(Delegation.self, from: Data(#"{"style":"always"}"#.utf8))
        #expect(old.talksItThrough)
    }
}
