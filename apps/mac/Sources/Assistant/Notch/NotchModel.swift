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

    // Text mode: nothing is said, the statuses are drawn and the chat is typed.
    @Published var mode: AssistantSettings.Mode = .voice
    @Published var roster = FleetRoster()
    @Published var chat = ChatLog()
    @Published var isOpen = false
    /// Something that just happened, shown under the closed notch for a moment.
    @Published var update: NotchUpdate?
    /// The pane of the agent the next message goes to. Nil sends it to the session.
    @Published var target: String?
    @Published var draft = ""
    /// Whether the list has been asked for the idle agents too.
    @Published var showsIdle = false
    /// What the session is doing right now, while it is mid-turn.
    @Published var working: String?
    /// How tall the island turned out once its contents were laid out.
    var laidOutHeight: Double = 0
    var onSend: ((String, AgentRow?) -> Void)?

    /// Centre of the eyes in screen coordinates, so they can follow the pointer.
    var anchor: CGPoint = .zero
    var onApproval: ((ApprovalRequest, Bool) -> Void)?
    /// A click on the island while it is awake sends it back to sleep.
    var onDismiss: (() -> Void)?

    init(assistantName: String) {
        self.assistantName = assistantName
    }

    var content: IslandContent {
        NotchLayout.content(phase: phase, caption: caption, approval: approval, fleet: fleet)
    }

    var textContent: TextContent {
        TextLayout.content(roster: roster, isOpen: isOpen, hasUpdate: update != nil, hasApproval: approval != nil)
    }

    var size: IslandSize {
        if mode == .text { return TextLayout.size(metrics: metrics, content: textContent, roster: roster) }
        return NotchLayout.size(metrics: metrics, content: content)
    }

    /// The island as it is on screen: text mode grows to fit what it holds.
    var footprint: CGSize {
        let size = self.size
        return CGSize(width: size.width, height: mode == .text ? max(size.height, laidOutHeight) : size.height)
    }

    var targetRow: AgentRow? {
        guard let target else { return nil }
        return roster.rows.first { $0.paneID == target }
    }

    func open() {
        guard mode == .text, !isOpen else { return }
        update = nil
        isOpen = true
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        showsIdle = false
    }

    func toggle() {
        if isOpen { close() } else { open() }
    }

    /// A click on an agent aims the message box at it; a second click lets go.
    func choose(_ row: AgentRow) {
        target = target == row.paneID ? nil : row.paneID
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSend?(text, targetRow)
    }

    /// Not while it is asking for a yes or a no: a stray click there must never
    /// count as an answer, or lose the question.
    func dismiss() {
        guard approval == nil, phase.isAwake else { return }
        onDismiss?()
    }

    func resolve(_ request: ApprovalRequest, allow: Bool) {
        onApproval?(request, allow)
        if approval?.id == request.id { approval = nil }
    }
}
