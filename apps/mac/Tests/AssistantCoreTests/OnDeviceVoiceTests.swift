import Foundation
import Testing
@testable import AssistantCore

@Suite struct OnDeviceVoiceTests {
    @Test func theSmallModelIsToldToStayQuietWhenItCannotMakeOutTheWords() {
        let prompt = LivePersona.onDevice(name: "Jarvis")
        #expect(prompt.contains("If you could not make out the words, reply SILENT too."))
        #expect(prompt.contains("never ask them to speak up"))
    }
}
