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

    init(model: NotchModel) {
        self.model = model
        steps = DemoStep.script(name: model.assistantName)
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
