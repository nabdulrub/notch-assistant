import Foundation
import Testing
@testable import AssistantCore

@Suite struct CustomisationTests {
    private func settings(_ change: (inout AssistantSettings) -> Void) -> AssistantSettings {
        var settings = AssistantSettings()
        change(&settings)
        return settings
    }

    private func decoded(_ json: String) throws -> AssistantSettings {
        try JSONDecoder().decode(AssistantSettings.self, from: Data(json.utf8))
    }

    @Test func aSettingsFileFromBeforeStillLoadsWithTheDefaults() throws {
        let settings = try decoded(#"{"assistantName": "Friday", "model": "opus"}"#)
        #expect(settings.delegation == Delegation())
        #expect(settings.personality.isEmpty)
        #expect(settings.customInstructions.isEmpty)
    }

    @Test func delegationValuesItDoesNotKnowFallBackAndTheWorkerCountIsKeptInRange() throws {
        let settings = try decoded(#"{"delegation": {"style": "telepathy", "runner": "subagents", "maxWorkers": 40}}"#)
        #expect(settings.delegation.style == .always)
        #expect(settings.delegation.runner == .subagents)
        #expect(settings.delegation.maxWorkers == Delegation.mostWorkers)
        #expect(Delegation(maxWorkers: 0).maxWorkers == 1)
    }

    @Test func settingsSurviveBeingSavedAndLoaded() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("notch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let written = settings {
            $0.delegation = Delegation(style: .handsOn, runner: .herdr, workerModel: "opus", lightWorkerModel: "haiku", maxWorkers: 5,
                                       askBeforeTouchingOthers: false)
            $0.personality = "Calm and precise."
            $0.customInstructions = "Open every pull request as a draft."
        }
        let store = SettingsStore(directory: directory)
        try store.save(written)
        #expect(store.load() == written)
    }

    @Test func byDefaultItNeverDoesTheWorkItself() {
        let prompt = Persona.instructions(for: AssistantSettings())
        #expect(prompt.contains("You never do the work yourself:"))
        #expect(prompt.contains("At most three of your own workers at a time."))
        #expect(prompt.contains("on the models they allow"))
        #expect(prompt.contains(#"Before sending input to an agent marked "not yours", ask the user out loud"#))
    }

    @Test func theOtherStylesLetItDoSomeOfTheWork() {
        let quick = Persona.instructions(for: settings { $0.delegation.style = .quickLooks })
        #expect(!quick.contains("You never do the work yourself:"))
        #expect(quick.contains("A quick look you take yourself"))
        #expect(quick.contains("Never change anything yourself"))
        let hands = Persona.instructions(for: settings { $0.delegation.style = .handsOn })
        #expect(hands.contains("Small jobs you do yourself"))
        #expect(!hands.contains("Never change anything yourself"))
    }

    @Test func chosenWorkerModelsAreNamedAndWinOverOtherRules() {
        let both = Persona.instructions(for: settings {
            $0.delegation.workerModel = "opus"
            $0.delegation.lightWorkerModel = "haiku"
        })
        #expect(both.contains("Real work runs on the opus model"))
        #expect(both.contains("quick lookups run on the haiku model"))
        #expect(both.contains("These choices win over any other rule"))
        #expect(!both.contains("the models the user's own instructions allow"))
        let one = Persona.instructions(for: settings { $0.delegation.workerModel = "opus" })
        #expect(one.contains("For everything else, use the models the user's own instructions allow."))
    }

    @Test func whereWorkersRunAndHowManyFollowTheSettings() {
        let prompt = Persona.instructions(for: settings {
            $0.delegation.runner = .subagents
            $0.delegation.maxWorkers = 1
            $0.delegation.askBeforeTouchingOthers = false
        })
        #expect(prompt.contains("Start workers as background subagents, not as herdr agents."))
        #expect(prompt.contains("Name every worker with the prefix jv-"))
        #expect(prompt.contains("At most one of your own workers at a time."))
        #expect(prompt.contains("without asking first"))
        #expect(!prompt.contains("ask the user out loud and wait for a yes"))
        #expect(Persona.instructions(for: settings { $0.delegation.runner = .herdr }).contains("Start workers as herdr agents, every time."))
    }

    @Test func aPersonaOfTheirOwnReplacesTheCharacterButNotHowSpeechWorks() {
        let prompt = Persona.instructions(for: settings { $0.personality = "  You are calm and a little formal.  " })
        #expect(prompt.contains("Be this in every reply:\n\nYou are calm and a little formal.\n\n"))
        #expect(!prompt.contains("Be funny."))
        #expect(!prompt.contains("Too stiff versus how you actually say it"))
        #expect(prompt.contains("The speak tool refuses anything over"))
        #expect(prompt.contains("Never read out structure."))
        #expect(prompt.contains("Every single reply, however short, is a call to the speak tool"))
    }

    @Test func theDefaultCharacterIsWhatTheDefaultPromptUses() {
        let prompt = Persona.instructions(for: AssistantSettings())
        for line in Persona.defaultCharacter.split(separator: "\n") { #expect(prompt.contains(line)) }
        #expect(Persona.defaultCharacter.contains("Be funny."))
    }

    @Test func theirOwnInstructionsComeLastAndAreSaidToWin() {
        let prompt = Persona.instructions(for: settings {
            $0.voiceEngine = "sophon"
            $0.customInstructions = "Open every pull request as a draft."
        })
        #expect(prompt.hasSuffix("every reply still goes through speak.\nOpen every pull request as a draft."))
        #expect(prompt.contains("they win over anything above"))
        #expect(!Persona.instructions(for: AssistantSettings()).contains("The user's own instructions. They wrote these"))
    }

    @Test func theVoiceInUseDecidesWhichLayerIsAdded() {
        #expect(Persona.instructions(for: settings { $0.voiceEngine = "sophon" }).contains("A small voice model on the user's Mac"))
        #expect(Persona.instructions(for: settings { $0.voiceEngine = "live" }).contains("the voice says it in its own words"))
    }

    @Test func aRunningSessionIsSentTheWholeThingAndToldToSayNothing() {
        let changed = settings { $0.customInstructions = "Never deploy on a Friday." }
        let update = Persona.update(for: changed)
        #expect(update.hasPrefix("The user changed your settings."))
        #expect(update.contains("do not call speak"))
        #expect(update.hasSuffix(Persona.instructions(for: changed)))
        #expect(Persona.instructions(for: changed).contains(#"kind="instructions"> is a new copy of these instructions"#))
        let line = ChannelServer(assistantName: "Jarvis").notification(for: .event(kind: "instructions", text: update))
        #expect(line.map { String(decoding: $0, as: UTF8.self) }?.contains("Never deploy on a Friday.") == true)
    }

    @Test func theLiveVoiceTakesTheirPersonaToo() {
        #expect(LivePersona.instructions(name: "Jarvis").contains("You are their buddy, not an assistant on a help desk."))
        let own = LivePersona.instructions(name: "Jarvis", personality: "You are calm and a little formal.")
        #expect(own.contains("Be this:\nYou are calm and a little formal."))
        #expect(!own.contains("You are their buddy, not an assistant on a help desk."))
        #expect(own.contains("Hand it over:"))
    }

    @Test func theHelperGivesTheWrittenInstructionsAsTheChannelsOwn() throws {
        let data = SessionCommand.mcpConfig(helperPath: "/h", assistantName: "Jarvis", socketPath: "/s", personaPath: "/p/persona.md")
        let config = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let server = try #require((config["mcpServers"] as? [String: Any])?[Persona.channelName] as? [String: Any])
        #expect(server["args"] as? [String] == ["--name", "Jarvis", "--socket", "/s", "--persona", "/p/persona.md"])
        #expect(ChannelServer(assistantName: "Jarvis", instructions: "Mine.").instructions == "Mine.")
        #expect(ChannelServer(assistantName: "Jarvis").instructions == Persona.instructions(name: "Jarvis"))
    }

    @Test func onlyWhatTheAppItselfUsesNeedsItStartedAgain() {
        let now = AssistantSettings()
        #expect(!now.needsRestart(toBecome: settings { $0.delegation.maxWorkers = 5 }))
        #expect(!now.needsRestart(toBecome: settings { $0.customInstructions = "x" }))
        #expect(!now.needsRestart(toBecome: settings { $0.model = "opus" }))
        #expect(now.needsRestart(toBecome: settings { $0.assistantName = "Friday" }))
        #expect(now.needsRestart(toBecome: settings { $0.updateEvery = 0 }))
        #expect(now.needsRestart(toBecome: settings { $0.personality = "x" }))
        let onDevice = settings { $0.voiceEngine = "sophon" }
        var changed = onDevice
        changed.personality = "x"
        #expect(!onDevice.needsRestart(toBecome: changed))
    }
}
