import AssistantCore
import Foundation

/// One frame of the walkthrough that `--demo` loops and `--snapshot` renders.
struct DemoStep {
    var name: String
    var phase: Phase
    var caption: String?
    var ownVoice = false
    var approval: ApprovalRequest?
    var fleet: FleetSummary?
    var level: Double = 0
    var seconds: Double
    /// Set for the frames of text mode.
    var text: TextFrame?

    /// What the notch holds in one frame of text mode.
    struct TextFrame {
        var roster = FleetRoster()
        var isOpen = false
        var update: NotchUpdate?
        var target: String?
        var draft = ""
        var showsIdle = false
        var working: String?
        var chat: [(ChatMessage.Role, String, AgentRow?)] = []
    }

    /// Text mode from end to end: everything idle, work going on, someone
    /// waiting, an update, the open chat, a message to one agent, an approval.
    static func textScript(name: String) -> [DemoStep] {
        func agent(_ pane: String, _ name: String, _ status: AgentSnapshot.Status, _ project: String, kind: String = "claude") -> AgentSnapshot {
            AgentSnapshot(paneID: pane, name: name, title: nil, status: status, directory: "/Users/you/dev/" + project, kind: kind)
        }
        let now = Date()
        let idle = (0..<10).map { agent("i\($0)", "scratch-\($0 + 1)", .idle, "notes") }
        let quiet = FleetRoster(agents: idle + [agent("c1", "codex-review", .idle, "storefront", kind: "codex"),
                                                agent("c2", "codex-tests", .idle, "storefront", kind: "codex")])
        let busy = FleetRoster(agents: [
            agent("p1", "vc7-impl", .working, "bytes-dashboard"),
            agent("p2", "menu-import", .working, "menu-manager"),
            agent("p3", "codex-review", .working, "storefront", kind: "codex"),
            agent("p4", "codex-tests", .idle, "storefront", kind: "codex"),
        ] + idle, workingSince: ["p1": now.addingTimeInterval(-12 * 60), "p2": now.addingTimeInterval(-3 * 60), "p3": now.addingTimeInterval(-40)])
        let waiting = FleetRoster(agents: [
            agent("p1", "vc7-impl", .blocked, "bytes-dashboard"),
            agent("p2", "menu-import", .done, "menu-manager"),
            agent("p3", "codex-review", .working, "storefront", kind: "codex"),
            agent("p4", "codex-tests", .idle, "storefront", kind: "codex"),
        ] + idle, workingSince: ["p3": now.addingTimeInterval(-12 * 60)])
        let said: [(ChatMessage.Role, String, AgentRow?)] = [
            (.you, "what is vc7-impl stuck on", nil),
            (.assistant, "It wants to run the migration against QA and is asking first. The rest of the branch is green.", nil),
        ]
        let picked = waiting.rows.first { $0.paneID == "p3" }
        let request = ApprovalRequest(
            id: "kqmzt", tool: "Bash", summary: "\(name) wants to push the branch",
            preview: "git push origin feature/gift-cards", clickOnly: true)
        return [
            DemoStep(name: "text-idle", phase: .followUp, seconds: 2.4, text: TextFrame(roster: quiet)),
            DemoStep(name: "text-working", phase: .followUp, seconds: 3.0, text: TextFrame(roster: busy)),
            DemoStep(name: "text-needs-you", phase: .followUp, seconds: 3.0, text: TextFrame(roster: waiting)),
            DemoStep(name: "text-update", phase: .followUp, seconds: 3.6,
                     text: TextFrame(roster: waiting, update: NotchUpdate(kind: "claude", title: "menu-import finished", detail: "menu-manager"))),
            DemoStep(name: "text-open", phase: .followUp, seconds: 4.5, text: TextFrame(roster: waiting, isOpen: true, chat: said)),
            DemoStep(name: "text-to-agent", phase: .thinking, seconds: 4.5,
                     text: TextFrame(roster: waiting, isOpen: true, target: "p3", draft: "also cover the refund path",
                                     working: "Reading the gift cards review",
                                     chat: said + [(.you, "skip the snapshot tests for now", picked)])),
            DemoStep(name: "text-all-agents", phase: .followUp, seconds: 3.6, text: TextFrame(roster: waiting, isOpen: true, showsIdle: true)),
            DemoStep(name: "text-approval", phase: .followUp, approval: request, seconds: 4.5, text: TextFrame(roster: waiting)),
            DemoStep(name: "text-nothing-running", phase: .followUp, seconds: 2.6, text: TextFrame(isOpen: true)),
        ]
    }

    static func script(name: String) -> [DemoStep] {
        let request = ApprovalRequest(
            id: "kqmzt", tool: "Bash", summary: "\(name) wants to push the branch",
            preview: "git push origin feature/gift-cards", clickOnly: true)
        return [
            DemoStep(name: "asleep", phase: .asleep, seconds: 2.0),
            DemoStep(name: "listening", phase: .listening, level: 0.4, seconds: 1.8),
            DemoStep(name: "listening-caption", phase: .listening,
                     caption: "How is the gift card build going", level: 0.6, seconds: 2.6),
            DemoStep(name: "thinking", phase: .thinking,
                     caption: "How is the gift card build going", seconds: 2.4),
            DemoStep(name: "speaking", phase: .speaking,
                     caption: "Two agents are still working. The reviewer finished with three notes.",
                     ownVoice: true, level: 0.7, seconds: 4.0),
            DemoStep(name: "follow-up", phase: .followUp,
                     fleet: FleetSummary(working: 2, needsYou: 0, finished: 1), seconds: 2.6),
            DemoStep(name: "approval", phase: .thinking, approval: request, seconds: 4.5),
            DemoStep(name: "speaking-after", phase: .speaking,
                     caption: "Pushed. I will tell you when the checks finish.",
                     ownVoice: true, level: 0.6, seconds: 3.0),
        ]
    }

    @MainActor
    func apply(to model: NotchModel) {
        model.phase = phase
        model.caption = caption
        model.captionIsOwnVoice = ownVoice
        model.approval = approval
        model.fleet = fleet
        model.level = level
        guard let text else { return }
        model.mode = .text
        model.roster = text.roster
        model.update = text.update
        model.target = text.target
        model.draft = text.draft
        model.showsIdle = text.showsIdle
        model.working = text.working
        var chat = ChatLog()
        for line in text.chat { chat.append(line.0, line.1, to: line.2) }
        model.chat = chat
        model.isOpen = text.isOpen
    }
}

/// Plays the script on a loop so the look and the motion can be judged before any
/// audio or session is wired in.
@MainActor
final class DemoDriver {
    private let model: NotchModel
    private let steps: [DemoStep]
    private var index = 0
    private var stepTimer: Timer?
    private var levelTimer: Timer?

    init(model: NotchModel, text: Bool = false) {
        self.model = model
        steps = text ? DemoStep.textScript(name: model.assistantName) : DemoStep.script(name: model.assistantName)
    }

    func start() {
        show(0)
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.wobble() }
        }
    }

    func show(_ position: Int) {
        index = position % steps.count
        let step = steps[index]
        step.apply(to: model)
        stepTimer?.invalidate()
        stepTimer = Timer.scheduledTimer(withTimeInterval: step.seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.show(self.index + 1)
            }
        }
    }

    /// Stands in for a real loudness meter: two sines that never quite line up.
    private func wobble() {
        let base = steps[index].level
        guard base > 0 else {
            if model.level != 0 { model.level = 0 }
            return
        }
        let time = Date().timeIntervalSinceReferenceDate
        let wave = (sin(time * 9.1) + sin(time * 14.7)) / 4 + 0.5
        model.level = min(1, max(0, base * (0.35 + wave)))
    }
}
