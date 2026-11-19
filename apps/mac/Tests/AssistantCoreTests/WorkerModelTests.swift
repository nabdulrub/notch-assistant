import Foundation
import Testing
@testable import AssistantCore

@Suite struct WorkerModelTests {
    private let set = Delegation(workerModel: "fable", lightWorkerModel: "opus")

    private func bash(_ command: String, _ delegation: Delegation? = nil) -> String? {
        WorkerModelCheck.refusal(tool: "Bash", input: ["command": command], delegation: delegation ?? set)
    }

    @Test func aWorkerOnAnotherModelIsRefusedWithTheModelToUse() throws {
        let reason = try #require(bash(#"P=$(herdr pane split --pane w3:pZR --direction down | cut -d'"' -f4); herdr agent start jv-ideas --kind claude --pane $P -- --model sonnet 2>&1 | tail -1"#))
        #expect(reason.contains("started on sonnet"))
        #expect(reason.contains("--model fable"))
        #expect(reason.contains("CLAUDE.md"))
    }

    @Test func aWorkerOnEitherSetModelGoesAhead() {
        #expect(bash("herdr agent start jv-fix --kind claude --pane w3:p1 -- --model fable") == nil)
        #expect(bash("herdr agent start jv-sweep --kind claude --pane w3:p1 -- --model opus --permission-mode plan") == nil)
        #expect(bash("herdr agent start jv-fix --kind claude --pane w3:p1 -- --model claude-fable-5-2") == nil)
        #expect(bash("herdr agent start jv-fix --kind claude --pane w3:p1 -- --model=Fable") == nil)
    }

    @Test func aWorkerWithNoModelNamedIsRefused() throws {
        let reason = try #require(bash("herdr agent start jv-fix --kind claude --pane w3:p1"))
        #expect(reason.contains("no model named"))
    }

    @Test func everyStartInOneCommandIsChecked() {
        #expect(bash("herdr agent start jv-a --kind claude --pane p1 -- --model fable && herdr agent start jv-b --kind claude --pane p2 -- --model haiku") != nil)
        #expect(bash("herdr agent start jv-a --kind claude --pane p1 -- --model fable; herdr agent start jv-b --kind claude --pane p2 -- --model opus") == nil)
    }

    @Test func aModelNamedForSomethingElseDoesNotCountForTheWorker() {
        #expect(bash("herdr agent start jv-a --kind claude --pane p1; echo --model fable") != nil)
    }

    @Test func otherCommandsAreLeftAlone() {
        #expect(bash("herdr agent read w3:pTW --lines 40") == nil)
        #expect(bash("git log --oneline -3") == nil)
        #expect(bash("herdr agent prompt jv-fix \"switch to --model sonnet thinking\"") == nil)
        #expect(WorkerModelCheck.refusal(tool: "Read", input: ["file_path": "/tmp/x"], delegation: set) == nil)
    }

    @Test func aSubagentOnAnotherModelIsRefusedToo() {
        #expect(WorkerModelCheck.refusal(tool: "Agent", input: ["model": "sonnet", "prompt": "x"], delegation: set) != nil)
        #expect(WorkerModelCheck.refusal(tool: "Agent", input: ["model": "opus", "prompt": "x"], delegation: set) == nil)
        #expect(WorkerModelCheck.refusal(tool: "Agent", input: ["prompt": "x"], delegation: set) == nil)
    }

    @Test func withAModelLeftToTheUsersOwnInstructionsNothingIsRefused() {
        #expect(bash("herdr agent start jv-a --kind claude --pane p1 -- --model sonnet", Delegation()) == nil)
        #expect(bash("herdr agent start jv-a --kind claude --pane p1 -- --model sonnet", Delegation(workerModel: "fable")) == nil)
    }

    @Test func oneModelForEverythingIsSaidAsOne() throws {
        let reason = try #require(bash("herdr agent start jv-a --kind claude --pane p1 -- --model sonnet", Delegation(workerModel: "opus", lightWorkerModel: "opus")))
        #expect(reason.contains("Workers run on the opus model."))
    }

    @Test func theSessionIsStartedWithTheCheck() throws {
        let command = SessionCommand(assistantName: "Jarvis", model: "opus", mcpConfigPath: "mcp.json", personaPath: "persona.md",
                                     settingsPath: "session-settings.json")
        #expect(command.arguments.suffix(2) == ["--settings", "session-settings.json"])
        let json = try #require(JSONSerialization.jsonObject(with: SessionCommand.sessionSettings(helperPath: "/Applications/Notch Assistant.app/Contents/MacOS/assistant-channel")) as? [String: Any])
        let hooks = try #require((json["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
        #expect(hooks.first?["matcher"] as? String == "Bash|Agent|Task")
        let line = try #require(((hooks.first?["hooks"] as? [[String: Any]])?.first)?["command"] as? String)
        #expect(line == "'/Applications/Notch Assistant.app/Contents/MacOS/assistant-channel' hook pre-tool-use")
    }
}
