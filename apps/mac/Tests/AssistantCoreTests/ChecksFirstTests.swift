import Testing
@testable import AssistantCore

@Suite struct ChecksFirstTests {
    @Test func theSessionChecksWithoutBeingToldTo() {
        let prompt = Persona.instructions(name: "Jarvis")
        #expect(prompt.contains("Check before you answer:"))
        #expect(prompt.contains("You do not need to be told to check."))
        #expect(prompt.contains("never from what you remember"))
    }

    @Test func whatItKnowsIsNoLongerAnAnswer() {
        #expect(!Persona.instructions(name: "Jarvis").contains("or in what you know"))
    }

    @Test func theVoiceOnThisMacHandsOverAnyQuestion() {
        let prompt = LivePersona.onDevice(name: "Jarvis")
        #expect(prompt.contains("Whenever they ask a question, about that or about anything else"))
        #expect(prompt.contains("hand it over"))
        #expect(!prompt.contains("small talk and banter"))
    }

    @Test func theLiveVoiceHandsOverWithoutTheWordCheck() {
        #expect(LivePersona.instructions(name: "Jarvis").contains("They do not have to say \"check\""))
    }
}
