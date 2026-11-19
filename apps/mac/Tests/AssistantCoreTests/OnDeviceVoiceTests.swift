import Foundation
import Testing
@testable import AssistantCore

@Suite struct OnDeviceVoiceTests {
    @Test func theSmallModelIsToldToStayQuietWhenItCannotMakeOutTheWords() {
        let prompt = LivePersona.onDevice(name: "Jarvis")
        #expect(prompt.contains("If you could not make out the words, reply SILENT too."))
        #expect(prompt.contains("never ask them to speak up"))
    }

    @Test func aRequestSaidWithTheNameIsReadFromTheTranscript() {
        let matcher = WakeMatcher(name: "Jarvis")
        #expect(matcher.match("Jarvis, can you check on Margo?")?.requestInTheSameBreath == "can you check on Margo")
        #expect(matcher.match("Hey Jarvis check Margo")?.requestInTheSameBreath == "check Margo")
        #expect(matcher.match("how's the build, Jarvis")?.requestInTheSameBreath == "how's the build")
    }

    @Test func theNameAloneOrWithOneWordIsNotARequest() {
        let matcher = WakeMatcher(name: "Jarvis")
        #expect(matcher.match("Jarvis")?.requestInTheSameBreath == nil)
        #expect(matcher.match("Hey Jarvis.")?.requestInTheSameBreath == nil)
        #expect(matcher.match("Jarvis, hello")?.requestInTheSameBreath == nil)
    }
}
