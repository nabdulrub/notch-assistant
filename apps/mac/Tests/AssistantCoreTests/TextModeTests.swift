import Foundation
import Testing
@testable import AssistantCore

private func agent(_ pane: String, _ name: String?, _ status: AgentSnapshot.Status, kind: String? = "claude",
                   title: String? = nil, directory: String? = "/Users/you/dev/storefront") -> AgentSnapshot {
    AgentSnapshot(paneID: pane, name: name, title: title, status: status, directory: directory, kind: kind)
}

@Suite struct TextModeSettingsTests {
    @Test func settingsWrittenBeforeTextModeStillLoadAsVoice() throws {
        let old = Data(#"{"assistantName":"Friday","voiceEngine":"sophon","setupDone":true}"#.utf8)
        let settings = try JSONDecoder().decode(AssistantSettings.self, from: old)
        #expect(settings.mode == .voice)
        #expect(settings.showWhileSharing == false)
        #expect(settings.assistantName == "Friday")
    }

    @Test func modeAndSharingSurviveARoundTrip() throws {
        let settings = AssistantSettings(mode: .text, showWhileSharing: true)
        let back = try JSONDecoder().decode(AssistantSettings.self, from: JSONEncoder().encode(settings))
        #expect(back == settings)
    }

    @Test func aModeItDoesNotKnowFallsBackToVoice() throws {
        let odd = Data(#"{"mode":"telepathy"}"#.utf8)
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: odd).mode == .voice)
    }

    @Test func changingModeNeedsARestartAndSharingDoesNot() {
        let voice = AssistantSettings()
        #expect(voice.needsRestart(toBecome: AssistantSettings(mode: .text)))
        #expect(!voice.needsRestart(toBecome: AssistantSettings(showWhileSharing: true)))
    }

    @Test func theSessionIsToldItIsTypedToOnlyInTextMode() {
        let text = Persona.instructions(for: AssistantSettings(mode: .text))
        #expect(text.contains("text mode"))
        #expect(text.contains("no markdown"))
        #expect(!text.contains("A small voice model on the user's Mac"))
        #expect(!Persona.instructions(for: AssistantSettings()).contains("text mode"))
        #expect(!Persona.instructions(for: AssistantSettings(voiceEngine: "sophon")).contains("text mode"))
    }

    @Test func switchingModeSendsTheSessionNewInstructions() {
        #expect(Persona.instructions(for: AssistantSettings()) != Persona.instructions(for: AssistantSettings(mode: .text)))
    }
}

@Suite struct RosterTests {
    @Test func herdrsKindIsRead() throws {
        let response = Data("""
            {"id":"list","result":{"agents":[
              {"pane_id":"w1:p1","agent":"codex","agent_status":"working","cwd":"/Users/you/dev/storefront","name":"review"},
              {"pane_id":"w1:p2","agent_status":"idle"}
            ]}}
            """.utf8)
        let agents = try #require(AgentSnapshot.list(from: response))
        #expect(agents.map(\.kind) == ["codex", nil])
    }

    @Test func sessionsAreCountedPerKindBiggestFirst() {
        let roster = FleetRoster(agents: [
            agent("1", "a", .idle, kind: "codex"),
            agent("2", "b", .working),
            agent("3", "c", .idle),
            agent("4", "d", .working, kind: "Codex"),
            agent("5", "e", .blocked),
        ])
        #expect(roster.kinds == [KindCount(kind: "claude", sessions: 3, working: 1), KindCount(kind: "codex", sessions: 2, working: 1)])
    }

    @Test func kindsWithTheSameCountKeepASteadyOrder() {
        let one = FleetRoster(agents: [agent("1", "a", .idle, kind: "codex"), agent("2", "b", .idle)])
        let other = FleetRoster(agents: [agent("2", "b", .idle), agent("1", "a", .idle, kind: "codex")])
        #expect(one.kinds == other.kinds)
        #expect(one.kinds.map(\.kind) == ["claude", "codex"])
    }

    @Test func anAgentHerdrHasNoKindForIsStillCounted() {
        let roster = FleetRoster(agents: [agent("1", "a", .working, kind: nil), agent("2", "b", .idle, kind: "")])
        #expect(roster.kinds == [KindCount(kind: FleetRoster.unknownKind, sessions: 2, working: 1)])
    }

    @Test func whoeverIsWaitingComesFirstThenWorkThenFinishedThenIdle() {
        let start = Date(timeIntervalSince1970: 1_000)
        let roster = FleetRoster(agents: [
            agent("idle", "idle", .idle),
            agent("done", "done", .done),
            agent("new", "new", .working),
            agent("old", "old", .working),
            agent("stuck", "stuck", .blocked),
        ], workingSince: ["new": start.addingTimeInterval(600), "old": start])
        #expect(roster.rows.map(\.paneID) == ["stuck", "old", "new", "done", "idle"])
        #expect(roster.active.count == 4)
        #expect(roster.needsYou == 1)
        #expect(roster.idle == 1)
        #expect(roster.rows[1].workingSince == start)
        #expect(roster.rows[0].workingSince == nil)
    }

    @Test func aRowIsCalledByItsNameThenItsTitleThenItsFolder() {
        let roster = FleetRoster(agents: [
            agent("1", "vc7-impl", .idle, title: "Claude Code"),
            agent("2", nil, .idle, title: "  Fixing the import  "),
            agent("3", "", .idle, title: ""),
            agent("4", nil, .idle, directory: nil),
        ])
        #expect(roster.rows.map(\.label) == ["vc7-impl", "Fixing the import", "storefront", "agent"])
        #expect(roster.rows.map(\.project) == ["storefront", "storefront", "storefront", nil])
    }

    @Test func theIdleLineCountsWhatIsFoldedAway() {
        #expect(FleetRoster(agents: [agent("1", "a", .idle)]).idleLine == "1 idle agent")
        #expect(FleetRoster(agents: [agent("1", "a", .idle), agent("2", "b", .idle)]).idleLine == "2 idle agents")
        #expect(FleetRoster(agents: [agent("1", "a", .working), agent("2", "b", .idle)]).idleLine == "1 more is idle")
        #expect(FleetRoster(agents: [agent("1", "a", .working), agent("2", "b", .idle), agent("3", "c", .unknown)]).idleLine == "2 more are idle")
    }

    @Test func theTrackerListsEveryoneButTheSessionItself() {
        var tracker = FleetTracker(ownName: "jarvis")
        let start = Date(timeIntervalSince1970: 5_000)
        let agents = [agent("own", "jarvis", .working), agent("w", "jv-worker", .working), agent("u", "mine", .idle, kind: "codex")]
        _ = tracker.update(agents, now: start)
        let update = tracker.update(agents, now: start.addingTimeInterval(90))
        #expect(update.roster.rows.map(\.paneID) == ["w", "u"])
        #expect(update.roster.rows[0].workingSince == start)
        #expect(update.roster.kinds.map(\.kind) == ["claude", "codex"])
    }

    @Test func elapsedTimeStaysShort() {
        #expect(Elapsed.short(-5) == "")
        #expect(Elapsed.short(59) == "")
        #expect(Elapsed.short(60) == "1m")
        #expect(Elapsed.short(12 * 60 + 40) == "12m")
        #expect(Elapsed.short(3600) == "1h")
        #expect(Elapsed.short(3600 + 5 * 60) == "1h 5m")
    }
}

@Suite struct ChatLogTests {
    @Test func emptyLinesAreNotKeptAndTextIsTrimmed() {
        var log = ChatLog()
        log.append(.you, "   ")
        log.append(.assistant, "  Done.\n")
        #expect(log.messages.map(\.text) == ["Done."])
    }

    @Test func onlyTheLastStretchIsKeptAndIdsNeverRepeat() {
        var log = ChatLog()
        for index in 0..<(ChatLog.most + 15) { log.append(.you, "line \(index)") }
        #expect(log.messages.count == ChatLog.most)
        #expect(log.messages.first?.text == "line 15")
        #expect(Set(log.messages.map(\.id)).count == ChatLog.most)
    }

    @Test func aMessageRemembersWhoItWasSentTo() {
        var log = ChatLog()
        let row = FleetRoster(agents: [agent("p3", "codex-review", .working, kind: "codex")]).rows[0]
        log.append(.you, "skip the snapshot tests", to: row)
        #expect(log.messages[0].to?.paneID == "p3")
    }
}

@Suite struct NotchUpdateTests {
    @Test func oneEventNamesTheAgentAndItsProject() {
        let update = NotchUpdate(FleetEvent(kind: .finished, agent: agent("1", "menu-import", .done, directory: "/Users/you/dev/menu-manager")))
        #expect(update == NotchUpdate(kind: "claude", title: "menu-import finished", detail: "menu-manager"))
        let stuck = NotchUpdate(FleetEvent(kind: .blocked, agent: agent("2", "vc7-impl", .blocked, kind: "codex")))
        #expect(stuck.title == "vc7-impl needs you")
        #expect(stuck.kind == "codex")
    }

    @Test func theFolderIsNotSaidTwice() {
        let update = NotchUpdate(FleetEvent(kind: .finished, agent: agent("1", nil, .done)))
        #expect(update.title == "storefront finished")
        #expect(update.detail == nil)
    }

    @Test func severalAtOncePutTheOneWaitingFirst() throws {
        let events = [
            FleetEvent(kind: .finished, agent: agent("1", "a", .done)),
            FleetEvent(kind: .blocked, agent: agent("2", "b", .blocked)),
            FleetEvent(kind: .finished, agent: agent("3", "c", .done)),
        ]
        let update = try #require(NotchUpdate(events: events))
        #expect(update.title == "b needs you")
        #expect(update.detail == "and 2 more")
        #expect(NotchUpdate(events: Array(events.prefix(2)))?.detail == "and 1 more")
        #expect(NotchUpdate(events: []) == nil)
    }
}

@Suite struct TextLayoutTests {
    let notch = NotchMetrics(width: 220, height: 38, hasHardwareNotch: true)
    let busy = FleetRoster(agents: [agent("1", "a", .working), agent("2", "b", .idle, kind: "codex")])
    let waiting = FleetRoster(agents: [agent("1", "a", .blocked), agent("2", "b", .idle, kind: "codex")])

    @Test func openWinsThenAnApprovalThenAnUpdate() {
        #expect(TextLayout.content(roster: busy, isOpen: true, hasUpdate: true, hasApproval: true) == .open)
        #expect(TextLayout.content(roster: busy, isOpen: false, hasUpdate: true, hasApproval: true) == .approval)
        #expect(TextLayout.content(roster: busy, isOpen: false, hasUpdate: true, hasApproval: false) == .update)
        #expect(TextLayout.content(roster: busy, isOpen: false, hasUpdate: false, hasApproval: false) == .tab)
    }

    @Test func withNoAgentsThereIsOnlyTheNotch() {
        #expect(TextLayout.content(roster: FleetRoster(), isOpen: false, hasUpdate: false, hasApproval: false) == .bare)
        let size = TextLayout.size(metrics: notch, content: .bare, roster: FleetRoster())
        #expect(size == NotchLayout.size(metrics: notch, content: .asleep))
    }

    @Test func theTabHangsOffTheRightOfTheNotchAndNoLower() {
        let size = TextLayout.size(metrics: notch, content: .tab, roster: busy)
        let tab = TextLayout.tabWidth(kinds: busy.kinds, needsYou: 0)
        #expect(tab > 0)
        #expect(size.height == notch.height)
        #expect(size.width == notch.width + tab)
        // Its left edge stays on the notch's left edge.
        #expect(size.shift - size.width / 2 == -notch.width / 2)
    }

    @Test func someoneWaitingMakesTheTabWider() {
        let calm = TextLayout.size(metrics: notch, content: .tab, roster: busy)
        let asking = TextLayout.size(metrics: notch, content: .tab, roster: waiting)
        #expect(asking.width > calm.width + 60)
        #expect(TextLayout.needsYouLabel(1) == "1 needs you")
        #expect(TextLayout.needsYouLabel(3) == "3 need you")
    }

    @Test func onlySessionsAtWorkAreCounted() {
        let idle = [KindCount(kind: "claude", sessions: 26, working: 0)]
        let three = [KindCount(kind: "claude", sessions: 26, working: 3)]
        let dozen = [KindCount(kind: "claude", sessions: 26, working: 12)]
        // Twenty-six idle sessions take no more room than one: there is no number.
        #expect(TextLayout.countsWidth(kinds: idle, needsYou: 0) == TextLayout.countsWidth(kinds: [KindCount(kind: "claude", sessions: 1, working: 0)], needsYou: 0))
        #expect(TextLayout.countsWidth(kinds: three, needsYou: 0) > TextLayout.countsWidth(kinds: idle, needsYou: 0))
        #expect(TextLayout.countsWidth(kinds: dozen, needsYou: 0) > TextLayout.countsWidth(kinds: three, needsYou: 0))
    }

    @Test func noMoreThanThreeKindsGetAnIcon() {
        let many = (0..<6).map { KindCount(kind: "kind\($0)", sessions: 2, working: 1) }
        #expect(TextLayout.countsWidth(kinds: many, needsYou: 0) == TextLayout.countsWidth(kinds: Array(many.prefix(3)), needsYou: 0))
    }

    @Test func everyShapeFitsTheCanvasWithTheTabAsWideAsItGets() {
        let crowd = FleetRoster(agents: (0..<120).map { agent("c\($0)", "a\($0)", .blocked) }
            + (0..<110).map { agent("x\($0)", "b\($0)", .working, kind: "codex") }
            + (0..<105).map { agent("g\($0)", "c\($0)", .working, kind: "gemini") })
        for content in [TextContent.bare, .tab, .update, .approval, .open] {
            let size = TextLayout.size(metrics: notch, content: content, roster: crowd)
            #expect(size.width / 2 + abs(size.shift) <= NotchLayout.canvasWidth / 2, "\(content)")
            #expect(size.height <= NotchLayout.canvasHeight)
        }
    }

    @Test func theOpenShapesCoverTheNotchAndAreCentredOnIt() {
        for content in [TextContent.update, .approval, .open] {
            let size = TextLayout.size(metrics: notch, content: content, roster: busy)
            #expect(size.width >= notch.width + 200)
            #expect(size.height == notch.height)
            #expect(size.shift == 0)
        }
        #expect(TextLayout.size(metrics: notch, content: .open, roster: busy).width == 480)
    }

    @Test func aScreenWithoutANotchGetsARowTallEnoughToRead() {
        #expect(TextLayout.barHeight(metrics: .floating) >= 28)
        let tab = TextLayout.size(metrics: .floating, content: .tab, roster: busy)
        #expect(tab.height >= 28)
        #expect(tab.shift == 0)
        #expect(TextLayout.size(metrics: .floating, content: .open, roster: busy).width >= 400)
    }
}

@Suite("Setup steps")
struct SetupStepTests {
    @Test("voice mode is asked everything")
    func voiceAsksEverything() {
        #expect(SetupStep.steps(for: .voice) == [.mode, .name, .voice, .microphone, .session, .ready])
    }

    @Test("text mode is never asked for a key, a model or the microphone")
    func textSkipsTheVoiceAndTheMicrophone() {
        #expect(SetupStep.steps(for: .text) == [.mode, .name, .session, .ready])
        #expect(SetupStep.name.next(in: .text) == .session)
        #expect(SetupStep.session.previous(in: .text) == .name)
    }

    @Test("the first step has nothing before it and the last nothing after")
    func theEnds() {
        for mode in [AssistantSettings.Mode.voice, .text] {
            #expect(SetupStep.mode.previous(in: mode) == nil)
            #expect(SetupStep.ready.next(in: mode) == nil)
        }
    }

    @Test("switching to text on a step text mode does not have still finds the way on")
    func aStepLeftBehindByAModeChange() {
        #expect(SetupStep.voice.next(in: .text) == .session)
        #expect(SetupStep.microphone.previous(in: .text) == .name)
    }

    @Test("progress ends at one in both modes and only ever grows")
    func progress() {
        for mode in [AssistantSettings.Mode.voice, .text] {
            let values = SetupStep.steps(for: mode).map { $0.progress(in: mode) }
            #expect(values.last == 1)
            #expect(values == values.sorted())
            #expect(Set(values).count == values.count)
        }
    }
}
