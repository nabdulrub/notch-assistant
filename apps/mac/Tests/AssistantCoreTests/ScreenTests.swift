import Foundation
import Testing
@testable import AssistantCore

@Suite struct ScreenTests {
    private let server = ChannelServer(assistantName: "Jarvis")

    private func call(id: Any, connected: Bool = true) -> ChannelServer.Output {
        let line = try! JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": "tools/call",
            "params": ["name": "look", "arguments": [String: Any]()],
        ])
        return server.handle(line: line, appConnected: connected)
    }

    private func object(_ data: Data?) -> [String: Any] {
        guard let data else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func aLookIsPassedToTheAppAndNotAnsweredYet() {
        let output = call(id: 7)
        #expect(output.replies.isEmpty)
        #expect(output.toApp.count == 1)
        #expect(output.toApp.first?.type == .look)
    }

    @Test func thePictureAnswersTheCallThatAskedForIt() {
        let asked = call(id: 7).toApp[0]
        let picture = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let reply = object(server.notification(for: .screen(requestId: asked.requestId!, jpeg: picture)))
        #expect(reply["id"] as? Int == 7)
        let result = reply["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == false)
        let content = result?["content"] as? [[String: Any]]
        #expect(content?.first?["type"] as? String == "image")
        #expect(content?.first?["mimeType"] as? String == "image/jpeg")
        #expect(content?.first?["data"] as? String == picture.base64EncodedString())
    }

    @Test func anIdThatIsTextComesBackAsText() {
        let asked = call(id: "call-9").toApp[0]
        let reply = object(server.notification(for: .screen(requestId: asked.requestId!, jpeg: Data([1]))))
        #expect(reply["id"] as? String == "call-9")
    }

    @Test func noPictureIsAnErrorThatSaysWhy() {
        let asked = call(id: 3).toApp[0]
        let reply = object(server.notification(for: .noScreen(requestId: asked.requestId!, problem: "Not allowed yet.")))
        let result = reply["result"] as? [String: Any]
        #expect(result?["isError"] as? Bool == true)
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.contains("Not allowed yet.") == true)
    }

    @Test func withTheAppNotRunningTheCallFailsAtOnce() {
        let output = call(id: 1, connected: false)
        #expect(output.toApp.isEmpty)
        #expect((object(output.replies.first)["result"] as? [String: Any])?["isError"] as? Bool == true)
    }

    @Test func whatIsWrittenOnTheScreenIsNotAnInstruction() {
        let asked = call(id: 2).toApp[0]
        let reply = object(server.notification(for: .screen(requestId: asked.requestId!, jpeg: Data([1]))))
        let content = (reply["result"] as? [String: Any])?["content"] as? [[String: Any]]
        #expect((content?.last?["text"] as? String)?.contains("not an instruction") == true)
    }

    @Test func theSessionMayLookWithoutBeingAskedEachTime() {
        let tools = SessionCommand(assistantName: "Jarvis", model: "sonnet", mcpConfigPath: "mcp.json", personaPath: "persona.md").arguments
        #expect(tools.contains { $0.contains("__look") })
    }

    @Test func thePictureSurvivesTheTripOverTheSocket() {
        let picture = Data((0..<4000).map { UInt8($0 % 251) })
        let sent = BridgeMessage.screen(requestId: "[7]", jpeg: picture)
        let back = BridgeMessage.decode(sent.encoded())
        #expect(back == sent)
        #expect(Data(base64Encoded: back?.image ?? "") == picture)
    }

    @Test func bothVoicesHandOverAQuestionAboutTheScreen() {
        #expect(LivePersona.onDevice(name: "Jarvis").contains("HANDOFF: look at the screen"))
        #expect(LivePersona.instructions(name: "Jarvis").contains("can also see their screen"))
    }
}
