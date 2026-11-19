import Foundation
import Testing
@testable import AssistantCore

@Suite struct WakeMatcherTests {
    let matcher = WakeMatcher(name: "Jarvis")

    @Test func nameThenRequestInOneBreath() {
        #expect(matcher.match("Jarvis, how's the gift card build going?")?.request == "how's the gift card build going")
        #expect(matcher.match("Hey Jarvis what's up")?.after == "what's up")
    }

    @Test func nameAtTheEndUsesWhatCameBefore() {
        let match = matcher.match("How's the build going, Jarvis?")
        #expect(match?.after == "")
        #expect(match?.request == "How's the build going")
    }

    @Test func theNameAloneIsAWakeWithNothingToSend() {
        #expect(matcher.match("Jarvis")?.request == "")
        #expect(matcher.match("hey jarvis.")?.request == "")
    }

    @Test func oneLetterOffStillCounts() {
        #expect(matcher.match("Jervis open the PR") != nil)
        #expect(matcher.match("jarvus open the PR") != nil)
        #expect(matcher.match("Jarvis's build is done") != nil)
    }

    /// The red control: ordinary talk, and near misses, must not wake it.
    @Test func ordinaryTalkDoesNotWake() {
        for line in [
            "so the service is down again",
            "can you ask Travis about the deploy",
            "the harvest numbers look fine",
            "I was telling Marcus about the build",
            "",
            "   ",
        ] {
            #expect(matcher.match(line) == nil, "woke on: \(line)")
        }
    }

    @Test func aShortNameMustMatchExactly() {
        let short = WakeMatcher(name: "Otto")
        #expect(short.match("Otto what time is it") != nil)
        #expect(short.match("auto save is on") == nil)
        #expect(short.match("lotto numbers") == nil)
    }

    @Test func aliasesAndTwoWordNames() {
        #expect(WakeMatcher(name: "Jarvis", aliases: ["service"]).match("service, status?")?.request == "status")
        #expect(WakeMatcher(name: "Big Mac").match("okay big mac run the tests")?.request == "run the tests")
        #expect(WakeMatcher(name: "Big Mac").match("that is a big deal") == nil)
    }
}

@Suite struct ConfirmationTests {
    @Test func yes() {
        for line in ["yes", "Yeah, go ahead.", "confirm", "sure do it", "okay", "Yep.", "approve it"] {
            #expect(Confirmation.parse(line) == .yes, "\(line)")
        }
    }

    @Test func no() {
        for line in ["no", "nope", "don't", "do not do that", "hold on", "cancel that", "yes... no wait"] {
            #expect(Confirmation.parse(line) == .no, "\(line)")
        }
    }

    @Test func anythingElseIsNotAnAnswer() {
        for line in ["", "what does it do", "hmm", "okay so I was thinking we should probably look at the other branch first"] {
            #expect(Confirmation.parse(line) == .unclear, "\(line)")
        }
    }
}

@Suite struct ApprovalPhraseTests {
    @Test func aCommandIsDescribedNotReadOut() {
        let spoken = ApprovalPhrase.spoken(tool: "Bash", description: "Push the branch to origin", preview: #"{"command":"git push origin feature/gift-cards"}"#)
        #expect(spoken == "Hey, so I wanna run a command: push the branch to origin. Cool if I go ahead?")
        #expect(!spoken.contains("git push"))
    }

    @Test func aCommandWithNoDescriptionStaysVague() {
        #expect(ApprovalPhrase.intent(tool: "Bash", description: "Run shell command", preview: "{}") == "run a command in the terminal")
    }

    @Test func filesAreNamedWithoutTheirPath() {
        let preview = #"{"file_path": "/Users/someone/dev/app/Sources/Core/NotchLayout.swift", "content": "…"}"#
        #expect(ApprovalPhrase.intent(tool: "Edit", description: "", preview: preview) == "edit NotchLayout.swift")
        #expect(ApprovalPhrase.intent(tool: "Write", description: "", preview: preview) == "write the file NotchLayout.swift")
        #expect(ApprovalPhrase.intent(tool: "Edit", description: "", preview: "garbage") == "edit a file")
    }

    @Test func toolsFromOtherServersAreNamedPlainly() {
        #expect(ApprovalPhrase.intent(tool: "mcp__linear__save_issue", description: "", preview: "") == "use save issue from linear")
        #expect(ApprovalPhrase.summary(tool: "WebSearch", description: "", preview: "") == "Okay to search the web?")
    }

    @Test func acronymsKeepTheirCapitals() {
        #expect(ApprovalPhrase.intent(tool: "Bash", description: "PR checks status", preview: "") == "run a command: PR checks status")
    }
}

@Suite struct VoiceGateTests {
    func run(_ gate: inout VoiceGate, rms: Double, seconds: Double) -> [VoiceGate.Transition] {
        var seen: [VoiceGate.Transition] = []
        var elapsed = 0.0
        while elapsed < seconds {
            if let transition = gate.feed(rms: rms, duration: 0.02) { seen.append(transition) }
            elapsed += 0.02
        }
        return seen
    }

    @Test func aVoiceOverAQuietRoomStartsAndEnds() {
        var gate = VoiceGate()
        #expect(run(&gate, rms: 0.001, seconds: 2).isEmpty)
        #expect(run(&gate, rms: 0.08, seconds: 0.5) == [.started])
        #expect(run(&gate, rms: 0.001, seconds: 0.4).isEmpty)
        #expect(run(&gate, rms: 0.001, seconds: 0.6) == [.ended])
    }

    @Test func aShortPauseBetweenWordsDoesNotEndIt() {
        var gate = VoiceGate()
        _ = run(&gate, rms: 0.001, seconds: 1)
        _ = run(&gate, rms: 0.08, seconds: 0.4)
        #expect(run(&gate, rms: 0.001, seconds: 0.3).isEmpty)
        #expect(run(&gate, rms: 0.08, seconds: 0.4).isEmpty)
        #expect(gate.isSpeaking)
    }

    @Test func aClickIsTooShortToCount() {
        var gate = VoiceGate()
        _ = run(&gate, rms: 0.001, seconds: 1)
        #expect(run(&gate, rms: 0.3, seconds: 0.04).isEmpty)
        #expect(!gate.isSpeaking)
    }

    @Test func steadyRoomNoiseIsLearnedAndIgnored() {
        var gate = VoiceGate()
        #expect(run(&gate, rms: 0.004, seconds: 20).isEmpty)
        #expect(run(&gate, rms: 0.005, seconds: 2).isEmpty)
        #expect(run(&gate, rms: 0.06, seconds: 0.5) == [.started])
    }

    @Test func silenceIsNeverSpeech() {
        var gate = VoiceGate()
        #expect(run(&gate, rms: 0, seconds: 5).isEmpty)
        #expect(run(&gate, rms: 0.0005, seconds: 1).isEmpty)
    }
}

@Suite struct ChannelServerTests {
    let server = ChannelServer(assistantName: "Jarvis")

    func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func send(_ json: String, connected: Bool = true) -> ChannelServer.Output {
        server.handle(line: Data(json.utf8), appConnected: connected)
    }

    @Test func initializeDeclaresTheChannelAndNeverAgreesToTheRevisionThatBlocksIt() {
        let reply = object(send(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2026-07-28"}}"#).replies[0])
        let result = reply["result"] as? [String: Any] ?? [:]
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        let capabilities = result["capabilities"] as? [String: Any] ?? [:]
        let experimental = capabilities["experimental"] as? [String: Any] ?? [:]
        #expect(experimental["claude/channel"] != nil)
        #expect(experimental["claude/channel/permission"] != nil)
        #expect(capabilities["tools"] != nil)
        #expect((result["instructions"] as? String ?? "").contains("Jarvis"))
        #expect(reply["id"] as? Int == 1)

        let echoed = object(send(#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#).replies[0])
        #expect((echoed["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-11-25")
    }

    @Test func listsItsTools() {
        let reply = object(send(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#).replies[0])
        let tools = (reply["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.compactMap { $0["name"] as? String } == ["speak", "show", "look"])
        #expect(reply["id"] as? String == "a")
    }

    @Test func speakGoesToTheAppAndAnswersAtOnce() {
        let output = send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"speak","arguments":{"text":" Build's done. ","expect_reply":true}}}"#)
        #expect(output.toApp == [.speak("Build's done.", expectReply: true)])
        let result = object(output.replies[0])["result"] as? [String: Any] ?? [:]
        #expect(result["isError"] as? Bool == false)
    }

    @Test func speakSaysSoWhenNobodyCanHear() {
        let output = send(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"speak","arguments":{"text":"hello"}}}"#, connected: false)
        #expect(output.toApp.isEmpty)
        let result = object(output.replies[0])["result"] as? [String: Any] ?? [:]
        #expect(result["isError"] as? Bool == true)
    }

    @Test func permissionPromptsAreRelayed() {
        let output = send(#"{"jsonrpc":"2.0","method":"notifications/claude/channel/permission_request","params":{"request_id":"kqmzt","tool_name":"Bash","description":"Push the branch","input_preview":"{\"command\":\"git push\"}"}}"#)
        #expect(output.replies.isEmpty)
        #expect(output.toApp == [.permissionRequest(id: "kqmzt", tool: "Bash", summary: "Push the branch", preview: #"{"command":"git push"}"#)])
    }

    @Test func notificationsGetNoAnswerAndUnknownRequestsGetAnError() {
        #expect(send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#).replies.isEmpty)
        let reply = object(send(#"{"jsonrpc":"2.0","id":9,"method":"resources/list"}"#).replies[0])
        #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(send("not json").replies.isEmpty)
    }

    @Test func whatTheUserSaidBecomesAChannelEvent() {
        let line = server.notification(for: .utterance("how's the build", source: "voice"))!
        let message = object(line)
        #expect(message["method"] as? String == "notifications/claude/channel")
        #expect(message["id"] == nil)
        let params = message["params"] as? [String: Any] ?? [:]
        #expect(params["content"] as? String == "how's the build")
        #expect((params["meta"] as? [String: String])?["kind"] == "speech")
    }

    @Test func metaKeysAreMadeIntoIdentifiersSoTheyAreNotDropped() {
        let line = server.notification(for: .event(kind: "agent", text: "finished", meta: ["pane-id": "w3:p1", "status": "done"]))!
        let meta = (object(line)["params"] as? [String: Any])?["meta"] as? [String: String] ?? [:]
        #expect(meta["kind"] == "agent")
        #expect(meta["pane_id"] == "w3:p1")
        #expect(meta["status"] == "done")
    }

    @Test func aVerdictGoesBackAsAllowOrDeny() {
        let allow = object(server.notification(for: .permissionVerdict(requestId: "kqmzt", allow: true))!)
        #expect(allow["method"] as? String == "notifications/claude/channel/permission")
        #expect((allow["params"] as? [String: String]) == ["request_id": "kqmzt", "behavior": "allow"])
        let deny = object(server.notification(for: .permissionVerdict(requestId: "kqmzt", allow: false))!)
        #expect((deny["params"] as? [String: String])?["behavior"] == "deny")
        #expect(server.notification(for: .speak("x")) == nil)
    }

    @Test func bridgeMessagesRoundTrip() {
        let message = BridgeMessage.event(kind: "agent", text: "done", meta: ["a": "b"])
        #expect(BridgeMessage.decode(message.encoded()) == message)
        #expect(BridgeMessage.decode(Data("nope".utf8)) == nil)
    }
}

@Suite struct SessionCommandTests {
    @Test func theSessionIsInteractiveAndPreapprovesItsOwnVoice() {
        let command = SessionCommand(assistantName: "Jarvis", model: "sonnet", mcpConfigPath: "/Users/x/Library/Application Support/NotchAssistant/mcp.json", personaPath: "/tmp/persona.md")
        #expect(!command.arguments.contains("-p"))
        #expect(!command.arguments.contains("--print"))
        #expect(command.arguments.contains("server:voice"))
        #expect(command.arguments.contains("mcp__voice__speak,mcp__voice__show,mcp__voice__look"))
        #expect(command.shellLine.contains("'/Users/x/Library/Application Support/NotchAssistant/mcp.json'"))
    }

    @Test func mcpConfigPointsAtTheHelper() throws {
        let data = SessionCommand.mcpConfig(helperPath: "/Apps/J.app/Contents/MacOS/assistant-channel", assistantName: "Jarvis", socketPath: "/tmp/b.sock")
        let config = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let server = (config?["mcpServers"] as? [String: Any])?["voice"] as? [String: Any]
        #expect(server?["command"] as? String == "/Apps/J.app/Contents/MacOS/assistant-channel")
        #expect(server?["args"] as? [String] == ["--name", "Jarvis", "--socket", "/tmp/b.sock"])
    }
}

@Suite struct NudgeTests {
    @Test func theLineTheHerdrPluginSendsIsUnderstood() {
        #expect(BridgeMessage.decode(Data(#"{"type":"nudge"}"#.utf8)) == .nudge)
    }

    @Test func aNudgeNeverReachesTheSession() {
        #expect(ChannelServer(assistantName: "Jarvis").notification(for: .nudge) == nil)
    }
}
