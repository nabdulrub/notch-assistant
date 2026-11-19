import Foundation
import Testing
@testable import AssistantCore

@Suite struct NotchLayoutTests {
    let notch = NotchMetrics(width: 190, height: 34, hasHardwareNotch: true)

    @Test func asleepIsExactlyTheNotch() {
        let size = NotchLayout.size(metrics: notch, content: .asleep)
        #expect(size.width == 190)
        #expect(size.height == 34)
    }

    @Test func everyAwakeShapeCoversTheNotchAndFitsTheCanvas() {
        for content in [IslandContent.eyes, .caption, .approval] {
            let size = NotchLayout.size(metrics: notch, content: content)
            #expect(size.width > notch.width)
            #expect(size.height > notch.height)
            #expect(size.width <= NotchLayout.canvasWidth)
            #expect(size.height <= NotchLayout.canvasHeight)
        }
    }

    @Test func shapesGrowInOrder() {
        let eyes = NotchLayout.size(metrics: notch, content: .eyes)
        let caption = NotchLayout.size(metrics: notch, content: .caption)
        let approval = NotchLayout.size(metrics: notch, content: .approval)
        #expect(eyes.height < caption.height)
        #expect(caption.height < approval.height)
        #expect(eyes.width <= caption.width)
        #expect(caption.width <= approval.width)
    }

    @Test func aScreenWithoutANotchStillGetsAUsableIsland() {
        let size = NotchLayout.size(metrics: .floating, content: .eyes)
        #expect(size.width >= 150)
        #expect(size.height >= 40)
    }

    @Test func approvalWinsOverEverything() {
        let request = ApprovalRequest(id: "abcde", tool: "Bash", summary: "Push", preview: "git push", clickOnly: true)
        #expect(NotchLayout.content(phase: .asleep, caption: nil, approval: request, fleet: nil) == .approval)
        #expect(NotchLayout.content(phase: .speaking, caption: "hi", approval: request, fleet: nil) == .approval)
    }

    @Test func asleepShowsNothingEvenWithACaptionLeftOver() {
        #expect(NotchLayout.content(phase: .asleep, caption: "stale", approval: nil, fleet: nil) == .asleep)
    }

    @Test func captionOnlyWhenThereIsText() {
        #expect(NotchLayout.content(phase: .listening, caption: nil, approval: nil, fleet: nil) == .eyes)
        #expect(NotchLayout.content(phase: .listening, caption: "", approval: nil, fleet: nil) == .eyes)
        #expect(NotchLayout.content(phase: .listening, caption: "how is the build", approval: nil, fleet: nil) == .caption)
    }
}

@Suite struct EyePoseTests {
    @Test func asleepEyesAreShut() {
        #expect(EyePose.at(time: 1, phase: .asleep, level: 1, gazeX: 1, gazeY: 1, lookingDown: false).openness == 0)
    }

    @Test func blinkShutsFullyNowAndThenAndIsOpenMostOfTheTime() {
        let samples = stride(from: 0.0, to: 60.0, by: 0.005).map(EyePose.blink(at:))
        #expect(samples.min()! < 0.05)
        #expect(Double(samples.filter { $0 == 1 }.count) / Double(samples.count) > 0.85)
    }

    @Test func listeningFollowsThePointerAndThinkingDoesNot() {
        let left = EyePose.at(time: 2, phase: .listening, level: 0, gazeX: -1, gazeY: 0, lookingDown: false)
        let right = EyePose.at(time: 2, phase: .listening, level: 0, gazeX: 1, gazeY: 0, lookingDown: false)
        #expect(left.dx < 0 && right.dx > 0)
        let thinkingLeft = EyePose.at(time: 2, phase: .thinking, level: 0, gazeX: -1, gazeY: 0, lookingDown: false)
        let thinkingRight = EyePose.at(time: 2, phase: .thinking, level: 0, gazeX: 1, gazeY: 0, lookingDown: false)
        #expect(thinkingLeft == thinkingRight)
        #expect(thinkingLeft.dy < 0)
    }

    @Test func speakingOpensWithTheVoice() {
        let quiet = EyePose.at(time: 2, phase: .speaking, level: 0, gazeX: 0, gazeY: 0, lookingDown: false)
        let loud = EyePose.at(time: 2, phase: .speaking, level: 1, gazeX: 0, gazeY: 0, lookingDown: false)
        #expect(loud.openness > quiet.openness)
    }

    @Test func anApprovalPullsTheEyesDown() {
        let pose = EyePose.at(time: 2, phase: .thinking, level: 0, gazeX: 1, gazeY: 0, lookingDown: true)
        #expect(pose.dx == 0)
        #expect(pose.dy > 0)
    }
}

@Suite struct FleetLayoutTests {
    @Test func fleetCountsOpenTheCaptionRowWhileAwakeOnly() {
        let fleet = FleetSummary(working: 2)
        #expect(NotchLayout.content(phase: .followUp, caption: nil, approval: nil, fleet: fleet) == .caption)
        #expect(NotchLayout.content(phase: .asleep, caption: nil, approval: nil, fleet: fleet) == .asleep)
        #expect(NotchLayout.content(phase: .followUp, caption: nil, approval: nil, fleet: FleetSummary()) == .eyes)
    }
}

@Suite struct FleetSummaryTests {
    @Test func needsYouLeads() {
        #expect(FleetSummary(working: 3, needsYou: 1, finished: 2).line == "1 needs you, 3 working, 2 finished")
        #expect(FleetSummary(working: 0, needsYou: 2, finished: 0).line == "2 need you")
        #expect(FleetSummary().isEmpty)
    }
}

@Suite struct SettingsTests {
    @Test func roundTripsAndDefaults() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        #expect(store.load().assistantName == "Jarvis")
        try store.save(AssistantSettings(assistantName: "Friday"))
        #expect(store.load().assistantName == "Friday")
    }

    @Test func aBlankNameFallsBack() throws {
        let data = Data(#"{"assistantName":"   "}"#.utf8)
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: data).assistantName == "Jarvis")
        #expect(try JSONDecoder().decode(AssistantSettings.self, from: Data("{}".utf8)).assistantName == "Jarvis")
    }
}

@Suite struct FleetTrackerTests {
    private func agent(_ pane: String, _ name: String, _ status: AgentSnapshot.Status) -> AgentSnapshot {
        AgentSnapshot(paneID: pane, name: name, title: nil, status: status, directory: nil)
    }

    @Test func aQuickAnswerFromAnAgentTheOrchestratorPromptedIsReported() {
        var tracker = FleetTracker(ownName: "jarvis")
        let start = Date()
        _ = tracker.update([agent("p1", "jarvis", .working), agent("p2", "margo", .idle)], now: start)
        _ = tracker.update([agent("p1", "jarvis", .working), agent("p2", "margo", .working)], now: start + 1)
        let update = tracker.update([agent("p1", "jarvis", .idle), agent("p2", "margo", .idle)], now: start + 6)
        #expect(update.events.map(\.kind) == [.finished])
        #expect(update.events.first?.asked == true)
    }

    @Test func aQuickTurnNobodyAskedForIsStillLeftOut() {
        var tracker = FleetTracker(ownName: "jarvis")
        let start = Date()
        _ = tracker.update([agent("p1", "jarvis", .idle), agent("p2", "margo", .idle)], now: start)
        _ = tracker.update([agent("p1", "jarvis", .idle), agent("p2", "margo", .working)], now: start + 1)
        let update = tracker.update([agent("p1", "jarvis", .idle), agent("p2", "margo", .done)], now: start + 6)
        #expect(update.events.isEmpty)
    }

    @Test func aLongTurnNobodyWatchedIsReported() {
        var tracker = FleetTracker(ownName: "jarvis")
        let start = Date()
        _ = tracker.update([agent("p2", "margo", .idle)], now: start)
        _ = tracker.update([agent("p2", "margo", .working)], now: start + 1)
        let update = tracker.update([agent("p2", "margo", .done)], now: start + 40)
        #expect(update.events.map(\.kind) == [.finished])
        #expect(update.events.first?.asked == false)
    }
}
