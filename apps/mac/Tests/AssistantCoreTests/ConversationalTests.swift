import Foundation
import Testing
@testable import AssistantCore

@Suite struct ConversationalTests {
    private func speak(_ text: String) -> [String: Any] {
        let line = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "speak", "arguments": ["text": text]],
        ])
        let output = ChannelServer(assistantName: "Jarvis").handle(line: line, appConnected: true)
        let reply = (try? JSONSerialization.jsonObject(with: output.replies[0]) as? [String: Any]) ?? [:]
        return reply["result"] as? [String: Any] ?? [:]
    }

    @Test func aSummaryIsRefused() {
        let summary = "The release is close. The last review fixes are pushed on the hotfix pull request. It's waiting on CI and a final sign-off, then it merges and ships."
        #expect(speak(summary)["isError"] as? Bool == true)
    }

    @Test func oneThingSaidToAFriendGoesThrough() {
        #expect(speak("Oh, the release is basically done. Just waiting on CI, then it ships. Want me to hold it?")["isError"] as? Bool == false)
    }

    @Test func everyExampleOfHowToSayItFitsTheLimit() {
        let examples = Persona.defaultCharacter.components(separatedBy: "You: \"").dropFirst().compactMap { $0.components(separatedBy: "\"").first }
        #expect(examples.count >= 10)
        for example in examples {
            let words = example.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            #expect(words <= ChannelServer.wordLimit, "\(words) words: \(example)")
        }
    }

    @Test func theCharacterIsAConversationNotABriefing() {
        #expect(Persona.defaultCharacter.contains("This is a conversation, not a briefing."))
        #expect(Persona.instructions(name: "Jarvis").contains("anything over \(ChannelServer.wordLimit) words"))
    }
}
