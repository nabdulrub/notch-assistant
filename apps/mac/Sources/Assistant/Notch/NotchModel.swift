import AssistantCore
import Combine
import Foundation

/// The one source the island draws from. Audio, the session bridge and the fleet
/// feed all write here; the views only read.
@MainActor
final class NotchModel: ObservableObject {
    @Published var assistantName: String
    @Published var phase: Phase = .asleep
    @Published var caption: String?
    /// True when the caption is the assistant's own words, false when it is what
    /// it heard from the user.
    @Published var captionIsOwnVoice = false
    /// While it is speaking: how many words of the caption have been said so far.
    @Published var captionProgress: Int?
    /// True when the caption is a label for what it is doing, like "Listening",
    /// and not anybody's words.
    @Published var captionIsStatus = false
    @Published var level: Double = 0
    @Published var approval: ApprovalRequest?
    @Published var fleet: FleetSummary?
    @Published var metrics: NotchMetrics = .floating

    /// Centre of the eyes in screen coordinates, so they can follow the pointer.
    var anchor: CGPoint = .zero
    var onApproval: ((ApprovalRequest, Bool) -> Void)?

    init(assistantName: String) {
        self.assistantName = assistantName
    }

    var content: IslandContent {
        NotchLayout.content(phase: phase, caption: caption, approval: approval, fleet: fleet)
    }

    var size: IslandSize {
        NotchLayout.size(metrics: metrics, content: content)
    }

    func resolve(_ request: ApprovalRequest, allow: Bool) {
        onApproval?(request, allow)
        if approval?.id == request.id { approval = nil }
    }
}
