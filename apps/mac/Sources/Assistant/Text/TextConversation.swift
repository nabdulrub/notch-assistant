import AssistantCore
import Foundation

/// Text mode: no microphone and no voice. The notch shows what every agent is
/// doing, says so in a line when one of them stops or finishes, and opens into
/// a chat that is typed.
///
/// A message goes to the Claude session behind the assistant unless an agent
/// was picked from the list; then it is typed straight into that agent's pane.
/// What the session answers with is shown, not said.
@MainActor
final class TextConversation {
    private let settings: AssistantSettings
    private let model: NotchModel
    private let bridge: BridgeServer
    private let hotkey = HotkeyManager()
    private let relay: FleetRelay
    private var sessionBusy = false
    private var note: String?
    private var looking = false
    private var updateTimer: Timer?

    private static let lookingLabel = "Looking at your screen"

    init(settings: AssistantSettings, model: NotchModel, bridge: BridgeServer) {
        self.settings = settings
        self.model = model
        self.bridge = bridge
        relay = FleetRelay(ownName: settings.assistantName.lowercased(), updateEvery: settings.updateEvery)
    }

    func start() {
        model.mode = .text
        bridge.onMessage = { [weak self] message in self?.received(message) }
        bridge.onLook = { [weak self] requestId, answer in self?.look(requestId, answer: answer) }
        bridge.onSessionCount = { count in Log.write(count > 0 ? "session attached" : "session detached") }
        model.onSend = { [weak self] text, row in self?.send(text, to: row) }
        model.onApproval = { [weak self] request, allow in self?.decide(request, allow: allow) }

        relay.onRoster = { [weak self] roster in
            guard let self, self.model.roster != roster else { return }
            self.model.roster = roster
        }
        relay.onEvents = { [weak self] events in
            guard let self, let update = NotchUpdate(events: events) else { return }
            self.show(update)
        }
        relay.onBusy = { [weak self] busy in
            guard let self else { return }
            self.sessionBusy = busy
            if !busy { self.note = nil }
            self.refresh()
        }
        relay.onNote = { [weak self] note in
            self?.note = note
            self?.refresh()
        }
        relay.isQuiet = { true }
        relay.send = { [weak self] message in self?.bridge.send(message) }
        relay.start()

        hotkey.onPress = { [weak self] in self?.model.toggle() }
        if !hotkey.register(settings.talkKey) { Log.write("could not register the talk key \(settings.talkKey.display)") }
        Log.write("text mode: no microphone. \(settings.talkKey.display) opens the chat")
        refresh()
    }

    // MARK: To the session and to the agents

    private func send(_ text: String, to row: AgentRow?) {
        model.chat.append(.you, text, to: row)
        guard let row else {
            Log.write("typed to the session: \(text)")
            if !bridge.send(.utterance(text, source: "typed")) {
                Log.write("no session attached")
                model.chat.append(.assistant, "No Claude session is attached.")
            }
            return
        }
        Log.write("typed to \(row.label) (pane \(row.paneID)): \(text)")
        let pane = row.paneID
        Task.detached { [weak self] in
            let problem = HerdrFeed.prompt(pane: pane, text: text)
            await self?.sent(to: row, problem: problem)
        }
    }

    private func sent(to row: AgentRow, problem: HerdrFeed.PromptProblem?) {
        relay.lookNow()
        guard let problem else { return }
        Log.write("could not reach \(row.label): \(problem)")
        switch problem {
        case .notRunning: model.chat.append(.assistant, "herdr is not running.")
        case .blocked: model.chat.append(.assistant, "\(row.label) is stopped on a question in its own pane.")
        case .gone: model.chat.append(.assistant, "\(row.label) is gone.")
        case .other(let why): model.chat.append(.assistant, why)
        }
    }

    // MARK: From the session

    private func received(_ message: BridgeMessage) {
        switch message.type {
        case .speak:
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Log.write("to show: \(text)")
            relay.spoke()
            model.chat.append(.assistant, text)
            show(NotchUpdate(title: text))
        case .show:
            let title = (message.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("note: \(title)")
            note = title.isEmpty ? nil : title
            refresh()
        case .permissionRequest:
            guard let id = message.requestId else { return }
            let tool = message.tool ?? "a tool"
            let preview = message.detail ?? ""
            Log.write("approval \(id) requested for \(tool)")
            model.update = nil
            model.approval = ApprovalRequest(
                id: id, tool: tool,
                summary: ApprovalPhrase.summary(tool: tool, description: message.text ?? "", preview: preview),
                preview: preview, clickOnly: true)
            refresh()
        case .utterance:
            // Typed in from the command line, with `--say`.
            send(message.text ?? "", to: nil)
        case .nudge:
            relay.lookNow()
        case .hello, .event, .permissionVerdict, .look, .screen:
            break
        }
    }

    private func decide(_ request: ApprovalRequest, allow: Bool) {
        Log.write("approval \(request.id) \(allow ? "allowed" : "denied") by click")
        bridge.send(.permissionVerdict(requestId: request.id, allow: allow))
        model.approval = nil
        refresh()
    }

    /// The session asked to see the screen. The notch says so for as long as it
    /// takes and a moment after, so a look never goes unnoticed.
    private func look(_ requestId: String, answer: @escaping @Sendable (BridgeMessage) -> Void) {
        Log.write("the session asked to see the screen")
        looking = true
        show(NotchUpdate(title: Self.lookingLabel), for: 5)
        refresh()
        Task { @MainActor [weak self] in
            do {
                let jpeg = try await ScreenEye.look()
                Log.write("sent it the screen, \(jpeg.count / 1024) KB")
                answer(.screen(requestId: requestId, jpeg: jpeg))
            } catch {
                let problem = (error as? ScreenEye.Problem) ?? .nothingToSee
                Log.write("could not show it the screen: \(problem)")
                answer(.noScreen(requestId: requestId, problem: problem.explanation))
            }
            try? await Task.sleep(for: .seconds(3))
            self?.looking = false
            self?.refresh()
        }
    }

    // MARK: The notch

    /// Closed, something new is shown under the notch for as long as it takes
    /// to read. Open, it is already in front of the user.
    private func show(_ update: NotchUpdate, for seconds: TimeInterval? = nil) {
        guard !model.isOpen, model.approval == nil else { return }
        model.update = update
        updateTimer?.invalidate()
        let words = Double(update.title.split(whereSeparator: { $0.isWhitespace }).count)
        updateTimer = Timer.scheduledTimer(withTimeInterval: seconds ?? min(12, 4 + words * 0.3), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.update == update else { return }
                self.model.update = nil
            }
        }
    }

    private func refresh() {
        let working: String? = looking ? Self.lookingLabel : sessionBusy ? (note ?? "Working on it") : nil
        if model.working != working { model.working = working }
        // The eyes are only ever seen beside something, so they are never shut.
        let phase: Phase = working == nil ? .followUp : .thinking
        if model.phase != phase { model.phase = phase }
    }
}
