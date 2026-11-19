import AVFoundation
import AssistantCore
import Foundation

/// Carries out what the turn machine decides. Everything that touches the
/// outside world (microphone, speaker, session, notch, timers) is here; every
/// decision about what happens next is in `TurnMachine`.
@MainActor
final class Conversation {
    private let settings: AssistantSettings
    private let model: NotchModel
    private let bridge: BridgeServer
    private let ears: Ears
    private let voice: Voice
    private let hotkey = HotkeyManager()
    private let fleet: HerdrFeed

    private var machine: TurnMachine
    private var timers: [TurnMachine.TimerKind: Timer] = [:]
    private var pressedAt: Date?
    private var lastSent: String?
    private var saying: String?
    /// Whether the session is in the middle of a turn, as herdr sees it.
    private var sessionBusy = false
    private var busySinceSend = false
    /// What the session last said it was doing.
    private var note: String?
    /// When the user last heard anything about the workers that are running.
    private var lastWorkerUpdate: Date?
    /// Set when it was cut off, until the session has been told.
    private var interruption: SpokenPortion?
    private var captionTimer: Timer?
    private var pendingReports: [FleetEvent] = []
    private var reportTimer: Timer?

    init(settings: AssistantSettings, model: NotchModel, bridge: BridgeServer, voice: Voice, engine: AVAudioEngine) {
        self.settings = settings
        self.model = model
        self.bridge = bridge
        self.voice = voice
        machine = TurnMachine(name: settings.assistantName, aliases: settings.wakeAliases)
        fleet = HerdrFeed(ownName: settings.assistantName.lowercased())
        ears = Ears(locale: Locale(identifier: settings.language),
                    contextWords: [settings.assistantName] + settings.wakeAliases,
                    engine: engine, echoCancel: settings.bargeIn)
    }

    func start() {
        bridge.onMessage = { [weak self] message in self?.received(message) }
        bridge.onSessionCount = { count in
            Log.write(count > 0 ? "session attached" : "session detached")
        }
        model.onApproval = { [weak self] request, allow in
            guard let self else { return }
            Log.write("approval \(request.id) \(allow ? "allowed" : "denied") by click")
            self.bridge.send(.permissionVerdict(requestId: request.id, allow: allow))
            self.dispatch(.approvalResolved(id: request.id))
            self.interruption = nil
        }

        fleet.onUpdate = { [weak self] update in
            guard let self else { return }
            let summary = update.summary
            let events = update.events
            let busy = update.own == .working
            self.checkIn(on: update.workers)
            if busy != self.sessionBusy {
                self.sessionBusy = busy
                Log.write(busy ? "session working" : "session idle")
                if busy {
                    self.busySinceSend = true
                } else {
                    self.note = nil
                    // It finished its turn without saying anything.
                    if self.machine.phase == .thinking, self.busySinceSend {
                        self.timers[.thinking]?.invalidate()
                        self.timers[.thinking] = nil
                        self.dispatch(.timer(.thinking))
                    }
                }
                self.sync()
            }
            let shown: FleetSummary? = summary.isEmpty ? nil : summary
            if self.model.fleet != shown { self.model.fleet = shown }
            self.report(events)
        }
        fleet.start()

        hotkey.onPress = { [weak self] in
            self?.pressedAt = Date()
            self?.dispatch(.talkPressed)
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return }
            let held = self.pressedAt.map { Date().timeIntervalSince($0) } ?? 0
            self.pressedAt = nil
            self.dispatch(.talkReleased(heldFor: held))
        }
        if !hotkey.register(settings.talkKey) {
            Log.write("could not register the talk key \(settings.talkKey.display)")
        }

        ears.onVoice = { [weak self] speaking in
            guard let self else { return }
            if speaking, self.machine.phase == .speaking {
                // A voice while it is talking only counts when that voice cannot be its own.
                guard self.ears.cancelsEcho, self.voice.isEchoCancelled else { return }
                Log.write("talked over")
            }
            self.dispatch(speaking ? .voiceStarted : .voiceEnded)
        }
        ears.onHeard = { [weak self] text in self?.dispatch(.heard(text)) }
        ears.onEnded = { [weak self] text in
            guard let self else { return }
            // What is said while it is asleep is checked for the name and then
            // forgotten. Only speech meant for it is written down.
            let addressed = self.machine.phase != .asleep
            self.dispatch(.utteranceEnded(text))
            if addressed || self.machine.phase != .asleep {
                Log.write("heard: \(text)")
            } else if !text.isEmpty {
                // A short one may be the name misheard, which is worth seeing
                // while the wake word is being tuned. Anything longer stays out.
                let words = text.split(separator: " ").count
                Log.write(words <= 3 ? "overheard, no name: \(text)" : "overheard \(words) words, no name")
            }
        }
        ears.onLevel = { [weak self] level in
            guard let self, self.model.phase == .listening || self.model.phase == .followUp else { return }
            self.model.level = level
        }
        Task { @MainActor in
            do {
                try await ears.start { [weak self] note in
                    Log.write(note)
                    self?.model.caption = note
                }
                Log.write("listening for \"\(settings.assistantName)\", talk key \(settings.talkKey.display)")
            } catch {
                Log.write("cannot listen: \(error)")
            }
        }
    }

    // MARK: From the session

    private func received(_ message: BridgeMessage) {
        switch message.type {
        case .speak:
            // The session moved on, so a prompt still on screen was answered in
            // the terminal.
            clearStaleApproval()
            dispatch(.speak(message.text ?? ""))
        case .show:
            Log.write("note: \(message.title ?? "") \(message.detail ?? "")")
            let title = (message.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = (message.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            note = title.isEmpty ? (detail.isEmpty ? nil : detail) : title
            sync()
        case .permissionRequest:
            guard let id = message.requestId else { return }
            let tool = message.tool ?? "a tool"
            let described = message.text ?? ""
            let preview = message.detail ?? ""
            Log.write("approval \(id) requested for \(tool)")
            model.approval = ApprovalRequest(
                id: id, tool: tool,
                summary: ApprovalPhrase.summary(tool: tool, description: described, preview: preview),
                preview: preview, clickOnly: false)
            dispatch(.approvalRequested(ApprovalRequest(id: id, tool: tool, summary: described, preview: preview, clickOnly: false)))
        case .utterance:
            dispatch(.typed(message.text ?? ""))
        case .hello, .event, .permissionVerdict:
            break
        }
    }

    /// While its workers are busy and nobody has said anything for a while, the
    /// session is asked to look in on them and tell the user where things are.
    private func checkIn(on workers: [AgentSnapshot]) {
        guard settings.updateEvery > 0, !workers.isEmpty else {
            lastWorkerUpdate = nil
            return
        }
        guard let last = lastWorkerUpdate else {
            lastWorkerUpdate = Date()
            return
        }
        guard Date().timeIntervalSince(last) >= settings.updateEvery,
              machine.phase == .asleep, !sessionBusy, machine.pendingApproval == nil else { return }
        lastWorkerUpdate = Date()
        let names = workers.map(\.label).joined(separator: ", ")
        Log.write("check-in on \(names)")
        note = "Checking on \(workers.count == 1 ? names : "the workers")"
        bridge.send(.event(kind: "checkin",
                           text: "Still working: \(names). The user has heard nothing for a while. Look at where they are and say one short line.",
                           meta: ["workers": String(workers.count)]))
    }

    /// Several agents often change state together, and each report costs the
    /// session a turn, so they are gathered for a few seconds and sent as one.
    private func report(_ events: [FleetEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            Log.write("fleet: \(event.text)")
            pendingReports.removeAll { $0.agent.paneID == event.agent.paneID }
            pendingReports.append(event)
        }
        guard reportTimer == nil else { return }
        // Its own workers are what the user is waiting on; those go out quickly.
        let wait: TimeInterval = pendingReports.contains { $0.agent.isOwn } ? 1.5 : 8
        reportTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushReports() }
        }
    }

    private func flushReports() {
        reportTimer = nil
        let events = pendingReports
        pendingReports.removeAll()
        guard !events.isEmpty else { return }
        let lines = events.map { event -> String in
            let project = event.agent.directory.map { ", in " + ($0 as NSString).lastPathComponent } ?? ""
            return "- \(event.text) (pane \(event.agent.paneID), \(event.agent.isOwn ? "your worker" : "not yours")\(project))"
        }
        note = "Checking in on the agents"
        bridge.send(.event(kind: "agents", text: lines.joined(separator: "\n"), meta: ["count": String(events.count)]))
    }

    private func clearStaleApproval() {
        guard let pending = machine.pendingApproval else { return }
        model.approval = nil
        dispatch(.approvalResolved(id: pending.id))
    }

    // MARK: The machine

    private func dispatch(_ event: TurnMachine.Event) {
        let before = machine.phase
        let effects = machine.handle(event)
        for effect in effects { perform(effect) }
        if machine.phase != before { Log.write("\(before.rawValue) -> \(machine.phase.rawValue)") }
        sync()
        if machine.phase == .asleep, let cut = interruption {
            // Cut off, and then nothing was said: it should still know the rest went unheard.
            interruption = nil
            bridge.send(.event(kind: "interrupted",
                               text: "They cut you off and then said nothing more. They heard: \"\(cut.heard)\". They did not hear: \"\(cut.missed)\".",
                               meta: [:]))
        }
    }

    private func perform(_ effect: TurnMachine.Effect) {
        switch effect {
        case .startListening:
            ears.startSession()
        case .stopListening:
            ears.stopSession()
        case .cancelListening:
            ears.cancelSession()
        case .send(let text):
            lastSent = text
            note = nil
            busySinceSend = false
            Log.write("sending: \(text)")
            var outgoing = text
            if let cut = interruption {
                interruption = nil
                outgoing = "(They cut you off mid-sentence. They heard: \"\(cut.heard)\". They did not hear: \"\(cut.missed)\".)\n\(text)"
            }
            if !bridge.send(.utterance(outgoing, source: "voice")) {
                Log.write("no session attached")
                DispatchQueue.main.async { [weak self] in
                    self?.dispatch(.speak("Uh, I'm not hooked up to a Claude session right now."))
                }
            }
        case .say(let text):
            saying = text
            if lastWorkerUpdate != nil { lastWorkerUpdate = Date() }
            Log.write("saying: \(text)")
            ears.setMode(settings.bargeIn && ears.cancelsEcho ? .guarded : .paused)
            followAlong(true)
            voice.say(text, onLevel: { [weak self] level in
                guard let self, self.model.phase == .speaking else { return }
                self.model.level = level
            }, onFinish: { [weak self] in
                guard let self else { return }
                self.saying = nil
                self.followAlong(false)
                self.ears.setMode(.open)
                self.dispatch(.speechFinished)
            })
        case .stopSpeaking:
            saying = nil
            followAlong(false)
            if let cut = voice.stop(), !cut.missed.isEmpty {
                interruption = cut
                Log.write("cut off after: \(cut.heard)")
            }
            ears.setMode(.open)
        case .decide(let request, let allow):
            Log.write("approval \(request.id) \(allow ? "allowed" : "denied") by voice")
            bridge.send(.permissionVerdict(requestId: request.id, allow: allow))
            interruption = nil
            model.approval = nil
        case .schedule(let kind, let seconds):
            timers[kind]?.invalidate()
            timers[kind] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.timers[kind] = nil
                    self?.dispatch(.timer(kind))
                }
            }
        case .cancel(let kind):
            timers[kind]?.invalidate()
            timers[kind] = nil
        }
    }

    /// Keeps the caption in step with the voice while it talks.
    private func followAlong(_ on: Bool) {
        captionTimer?.invalidate()
        captionTimer = nil
        model.captionProgress = on ? 0 : nil
        guard on else { return }
        captionTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let spoken = self.voice.wordsSpoken else { return }
                if self.model.captionProgress != spoken { self.model.captionProgress = spoken }
            }
        }
    }

    /// Mirrors the machine into what the notch draws.
    private func sync() {
        // Asleep but the session is mid-turn: keep the eyes up so it is plain that
        // something is happening.
        let working = sessionBusy && machine.phase == .asleep
        let shown: Phase = working ? .thinking : machine.phase
        if model.phase != shown { model.phase = shown }
        let caption: String?
        let ownVoice: Bool
        switch shown {
        case .asleep, .followUp:
            caption = nil
            ownVoice = false
        case .listening:
            caption = machine.utterance.isEmpty ? nil : machine.utterance
            ownVoice = false
        case .thinking:
            caption = note ?? (working ? "Working on it" : lastSent)
            ownVoice = false
        case .speaking:
            caption = saying
            ownVoice = true
        }
        if model.caption != caption { model.caption = caption }
        if model.captionIsOwnVoice != ownVoice { model.captionIsOwnVoice = ownVoice }
        if shown == .asleep || shown == .thinking, model.level != 0 { model.level = 0 }
        if machine.pendingApproval == nil, model.approval != nil { model.approval = nil }
    }
}
