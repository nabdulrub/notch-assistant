import AVFoundation
import AssistantCore
import Foundation

/// The conversation: a full-duplex voice model does the talking, and the
/// Claude session behind it does the work.
///
/// Asleep, nothing leaves the Mac: the name is listened for on-device. Once
/// woken, the microphone is streamed to the voice model, which handles whose
/// turn it is, being talked over, and small talk. When it is asked for
/// something real it hands off, and the request goes to the Claude session.
/// What the session says comes back through the voice.
@MainActor
final class LiveConversation {
    private enum State {
        case asleep
        case connecting
        case awake
    }

    private let settings: AssistantSettings
    private let model: NotchModel
    private let bridge: BridgeServer
    private let makeLine: () -> VoiceLine
    private let ears: Ears
    private let player: PCMPlayer
    private let hotkey = HotkeyManager()
    private let relay: FleetRelay
    private let matcher: WakeMatcher

    private var state: State = .asleep
    private var session: VoiceLine?
    private var dialogue = Dialogue()
    /// How much of the dialogue the session has already been given.
    private var handedOver = 0
    private var openHandOff: String?
    private var waitingToSay: [String] = []
    /// When it last spoke, was handed something, or was given something to say.
    private var lastEngaged = Date()
    /// When the voice model last recognised words from the microphone.
    private var lastWords = Date.distantPast
    private var openedAt = Date()
    /// A session is never left open longer than this, whatever is going on.
    private static let longestSession: TimeInterval = 300
    /// When its speech last ran out, so a gap between two pieces of audio does
    /// not flick the notch to another state and back.
    private var lastPlayedAt = Date.distantPast
    private var playingSince: Date?
    /// How long words in the room can hold a session open past its quiet limit.
    private static let longestWait: TimeInterval = 20
    /// Which of its lines the caption is following, and since when.
    private var following: (index: Int, since: Date)?
    private var displayTimer: Timer?
    private var idleTimer: Timer?
    private var checkingForName = false
    private var userTalking = false
    private var sessionBusy = false
    private var note: String?
    private var answer: String?
    private var answerTimer: Timer?
    private var loggedLines = 0
    /// A yes or no the session is waiting on, until it has been put to the user.
    private var pendingQuestion: String?

    /// - Parameter line: opens a new line to the voice model each time it wakes.
    init(settings: AssistantSettings, model: NotchModel, bridge: BridgeServer, engine: AVAudioEngine, line: @escaping () -> VoiceLine) {
        self.settings = settings
        self.model = model
        self.bridge = bridge
        makeLine = line
        matcher = WakeMatcher(name: settings.assistantName, aliases: settings.wakeAliases)
        ears = Ears(locale: Locale(identifier: settings.language),
                    contextWords: [settings.assistantName] + settings.wakeAliases,
                    engine: engine, echoCancel: true)
        player = PCMPlayer(engine: engine)
        relay = FleetRelay(ownName: settings.assistantName.lowercased(), updateEvery: settings.updateEvery)
    }

    func start() {
        bridge.onMessage = { [weak self] message in self?.received(message) }
        bridge.onSessionCount = { count in Log.write(count > 0 ? "session attached" : "session detached") }
        model.onApproval = { [weak self] request, allow in self?.decide(request, allow: allow, how: "click") }

        relay.onSummary = { [weak self] summary in
            guard let self, self.model.fleet != summary else { return }
            self.model.fleet = summary
        }
        relay.onBusy = { [weak self] busy in
            guard let self else { return }
            self.sessionBusy = busy
            if !busy {
                self.note = nil
                self.openHandOff = nil
            }
            self.refresh()
        }
        relay.isQuiet = { [weak self] in
            guard let self else { return true }
            return !self.player.isPlaying && !self.userTalking
        }
        relay.send = { [weak self] message in self?.bridge.send(message) }
        relay.onNote = { [weak self] note in
            self?.note = note
            self?.refresh()
        }
        relay.start()

        hotkey.onPress = { [weak self] in self?.talkKey() }
        if !hotkey.register(settings.talkKey) { Log.write("could not register the talk key \(settings.talkKey.display)") }

        player.onLevel = { [weak self] level in
            guard let self, self.model.phase == .speaking else { return }
            self.model.level = level
        }
        player.onPlaying = { [weak self] playing in
            guard let self else { return }
            self.lastEngaged = Date()
            if !playing { self.lastPlayedAt = Date() }
            self.playingSince = playing ? Date() : nil
            if self.ears.cancelsEcho {
                self.ears.setMode(playing ? .guarded : .open)
                // The loudness check starts over when the mode changes, and it
                // will not report the end of a voice it has forgotten.
                if playing { self.userTalking = false }
            } else {
                // No echo cancellation: stop it hearing itself the blunt way.
                self.session?.setMuted(playing)
            }
            self.refresh()
        }

        ears.onLevel = { [weak self] level in
            guard let self, self.model.phase == .listening || self.model.phase == .followUp else { return }
            self.model.level = level
        }
        ears.onVoice = { [weak self] speaking in self?.voice(speaking) }
        ears.onHeard = { [weak self] text in
            guard let self, self.state == .asleep, let match = self.matcher.match(text), match.leadsWithName else { return }
            self.wake("heard its name", byVoice: true)
        }
        ears.onEnded = { [weak self] text in
            guard let self else { return }
            self.checkingForName = false
            guard self.state == .asleep else { return }
            if let match = self.matcher.match(text), match.leadsWithName || match.endsWithName {
                self.wake("heard its name", byVoice: true)
            } else if !text.isEmpty {
                let words = text.split(separator: " ").count
                Log.write(words <= 3 ? "overheard, no name: \(text)" : "overheard \(words) words, no name")
            }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }

        Task { @MainActor in
            do {
                try await ears.start { note in Log.write(note) }
                Log.write("listening for \"\(settings.assistantName)\", talk key \(settings.talkKey.display)")
            } catch {
                Log.write("cannot listen: \(error)")
            }
        }
    }

    // MARK: Waking and sleeping

    private func wake(_ why: String, byVoice: Bool = false) {
        guard state == .asleep else { return }
        Log.write("waking: \(why)")
        state = .connecting
        openedAt = Date()
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        checkingForName = false
        ears.cancelSession()
        lastEngaged = Date()

        let session = makeLine()
        self.session = session
        session.onStarted = { [weak self, weak session] in
            guard let self, let session, self.session === session else { return }
            self.state = .awake
            Log.write("voice line open")
            if !self.dialogue.lines.isEmpty {
                let earlier = Dialogue(lines: Array(self.dialogue.lines.suffix(12)))
                session.remember("Earlier in this conversation:\n" + earlier.rendered(from: 0, voiceName: self.settings.assistantName), handOff: nil)
            }
            let queued = self.waitingToSay
            self.waitingToSay.removeAll()
            queued.forEach { self.say($0) }
            self.refresh()
        }
        session.onAudio = { [weak self, weak session] bytes in
            guard let self, self.session === session else { return }
            self.player.play(bytes)
        }
        session.onUserText = { [weak self, weak session] text in
            guard let self, self.session === session else { return }
            // Words the voice model recognised while it was talking: that is the
            // user talking over it. Loudness alone is not, in a room with people in it.
            // Words that arrive just as it starts talking are the end of what
            // it is answering, not someone talking over it.
            if self.player.isPlaying, let since = self.playingSince, Date().timeIntervalSince(since) > 1.2 { self.dialogue.markCutOff() }
            self.dialogue.append(.user, text)
            self.logFinishedLines()
            self.lastWords = Date()
            if let said = self.dialogue.latest(.user)?.text, Dismissal.matches(said) {
                self.sleep("told to stop")
                return
            }
            self.collectAnswer(text)
            self.refresh()
        }
        session.onVoiceText = { [weak self, weak session] text in
            guard let self, self.session === session else { return }
            self.dialogue.append(.voice, text)
            self.logFinishedLines()
            self.lastEngaged = Date()
            self.relay.spoke()
            self.refresh()
        }
        session.onHandOff = { [weak self, weak session] id in
            guard let self, self.session === session else { return }
            self.openHandOff = id
            self.lastEngaged = Date()
            self.refresh()
            // The hand-off carries no words, and the transcript trails the audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated { self?.handOver(id) }
            }
        }
        session.onCutIn = { [weak self, weak session] in
            guard let self, self.session === session else { return }
            if self.player.isPlaying { self.dialogue.markCutOff() }
            self.player.flush()
            self.refresh()
        }
        session.onDismissed = { [weak self, weak session] in
            guard let self, self.session === session else { return }
            self.sleep("told to stop")
        }
        session.onEnded = { [weak self, weak session] asked in
            guard let self, self.session === session else { return }
            if !asked { Log.write("voice line ended on its own") }
            self.session = nil
            self.settle()
        }
        session.open()
        ears.startStreaming(lead: byVoice) { [weak session] data in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session?.sendAudio(data) }
            }
        }
        refresh()
    }

    private func sleep(_ why: String) {
        guard state != .asleep else { return }
        Log.write("sleeping: \(why)")
        let ending = session
        session = nil
        ending?.onEnded = nil
        ending?.close()
        settle()
    }

    /// Writes down each line of the conversation once it is complete.
    private func logFinishedLines(all: Bool = false) {
        let upTo = all ? dialogue.lines.count : dialogue.lines.count - 1
        while loggedLines < upTo {
            let line = dialogue.lines[loggedLines]
            Log.write("\(line.speaker == .user ? "user" : "voice"): \(line.text.trimmingCharacters(in: .whitespacesAndNewlines))")
            loggedLines += 1
        }
    }

    /// Back to listening for the name only.
    private func settle() {
        logFinishedLines(all: true)
        displayTimer?.invalidate()
        displayTimer = nil
        following = nil
        ears.stopStreaming()
        player.flush()
        ears.setMode(.open)
        state = .asleep
        openHandOff = nil
        userTalking = false
        model.level = 0
        refresh()
    }

    /// A live session is billed for every minute it is open, so it is closed as
    /// soon as the conversation is over: nothing said by it or handed to it for a
    /// while, and the user not mid-sentence. People talking nearby do not keep it
    /// open. Whatever the session has to say later reopens it.
    private func checkIdle() {
        guard state != .asleep else { return }
        let now = Date()
        if now.timeIntervalSince(max(lastWords, lastEngaged)) > Dialogue.gap { logFinishedLines(all: true) }
        if now.timeIntervalSince(openedAt) > Self.longestSession {
            sleep("open for \(Int(Self.longestSession / 60)) minutes")
            return
        }
        guard state == .awake else {
            // Never connected: do not sit waiting on a socket.
            if now.timeIntervalSince(openedAt) > 15 { sleep("could not connect") }
            return
        }
        if player.isPlaying || model.approval != nil {
            lastEngaged = now
            return
        }
        let quiet = now.timeIntervalSince(lastEngaged)
        // Someone mid-sentence is heard out, but a room that never stops
        // talking does not get to keep the line open.
        if quiet > settings.liveIdle, now.timeIntervalSince(lastWords) > 1.5 || quiet > settings.liveIdle + Self.longestWait {
            sleep("quiet for \(Int(now.timeIntervalSince(lastEngaged)))s")
        }
    }

    private func talkKey() {
        switch state {
        case .asleep:
            wake("talk key")
        case .connecting, .awake:
            if player.isPlaying {
                // Its speech arrives about as fast as it is spoken, so there is
                // only a moment of it queued here to throw away.
                Log.write("cut off with the talk key")
                session?.interrupt()
                player.flush()
                dialogue.markCutOff()
            } else {
                sleep("talk key")
            }
        }
    }

    // MARK: Microphone

    private func voice(_ speaking: Bool) {
        userTalking = speaking
        switch state {
        case .asleep:
            if speaking, !checkingForName {
                checkingForName = true
                ears.startSession()
            } else if !speaking, checkingForName {
                ears.stopSession()
            }
        case .connecting, .awake:
            break
        }
        refresh()
    }

    // MARK: To and from the Claude session

    private func handOver(_ id: String) {
        guard openHandOff == id else { return }
        let said = dialogue.rendered(from: handedOver, voiceName: settings.assistantName)
        handedOver = dialogue.lines.count
        Log.write("handing over:\n\(said)")
        let message = "The voice handed this to you. What has been said since you were last asked:\n\(said)"
        if !bridge.send(.utterance(message, source: "voice")) {
            Log.write("no session attached")
            session?.say(session?.speaksWordForWord == true
                ? "I'm not hooked up to a Claude session right now."
                : "Tell them you are not hooked up to a Claude session right now.", handOff: id)
        }
    }

    private func received(_ message: BridgeMessage) {
        switch message.type {
        case .speak:
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Log.write("to say: \(text)")
            relay.spoke()
            say(text)
        case .show:
            let title = (message.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("note: \(title)")
            note = title.isEmpty ? nil : title
            refresh()
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
            answer = ""
            // The question is asked through whichever line is open, or the one about to be.
            pendingQuestion = ApprovalPhrase.spoken(tool: tool, description: described, preview: preview)
            say(pendingQuestion ?? "")
            refresh()
        case .utterance:
            // Typed in from the command line, for testing without a microphone.
            bridge.send(.utterance(message.text ?? "", source: "typed"))
        case .nudge:
            relay.lookNow()
        case .hello, .event, .permissionVerdict:
            break
        }
    }

    private func say(_ text: String) {
        lastEngaged = Date()
        if state == .awake, let session {
            // A model that retells what it is given has to be told that this
            // one is a question to put, not a fact to pass on.
            let isQuestion = text == pendingQuestion
            if isQuestion { pendingQuestion = nil }
            session.say(isQuestion && !session.speaksWordForWord ? "Ask the user this, then wait for a yes or a no: " + text : text,
                        handOff: openHandOff)
        } else {
            waitingToSay.append(text)
            wake("the session has something to say")
        }
    }

    // MARK: Approvals

    /// After it asks for a yes or no, the next thing the user says is the answer.
    private func collectAnswer(_ fragment: String) {
        guard model.approval != nil, let soFar = answer else { return }
        answer = soFar + fragment
        answerTimer?.invalidate()
        answerTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let request = self.model.approval, let said = self.answer else { return }
                self.answer = nil
                switch Confirmation.parse(said) {
                case .yes: self.decide(request, allow: true, how: "voice")
                case .no: self.decide(request, allow: false, how: "voice")
                case .unclear: Log.write("approval answer unclear; waiting for a click")
                }
            }
        }
    }

    private func decide(_ request: ApprovalRequest, allow: Bool, how: String) {
        Log.write("approval \(request.id) \(allow ? "allowed" : "denied") by \(how)")
        bridge.send(.permissionVerdict(requestId: request.id, allow: allow))
        model.approval = nil
        answer = nil
        answerTimer?.invalidate()
        session?.remember("The user answered \(allow ? "yes" : "no") to that request, and it has been \(allow ? "allowed" : "refused"). Do not ask again.", handOff: nil)
        refresh()
    }

    // MARK: The notch

    /// How fast the caption lights up, in words a second. The voice model sends
    /// its words about as fast as it says them, without saying exactly when.
    private static let readingPace = 2.9
    private static let listeningLabel = "Listening"

    private func refresh() {
        let now = Date()
        var phase: Phase
        var caption: String?
        var ownVoice = false
        var progress: Int?
        switch state {
        case .asleep:
            phase = sessionBusy ? .thinking : .asleep
            if sessionBusy { caption = note ?? "Working on it" }
        case .connecting:
            phase = .listening
        case .awake:
            let speaking = player.isPlaying || now.timeIntervalSince(lastPlayedAt) < 0.7
            if speaking, let line = dialogue.latest(.voice) {
                phase = .speaking
                if following?.index != line.index { following = (line.index, now) }
                let words = line.text.split(separator: " ").count
                caption = line.text
                ownVoice = true
                progress = min(words, Int(now.timeIntervalSince(following?.since ?? now) * Self.readingPace) + 1)
            } else if openHandOff != nil || sessionBusy {
                phase = .thinking
                caption = note ?? "Working on it"
            } else {
                // What the user says is not written out: the words arrive late
                // and in bursts, and a steady label reads better than text that
                // keeps correcting itself.
                // Only while they are actually speaking. Awake and waiting, the
                // open eyes say enough.
                let talking = userTalking || now.timeIntervalSince(lastWords) < 1.2
                phase = talking ? .listening : .followUp
                caption = talking ? Self.listeningLabel : nil
            }
        }
        if model.phase != phase { model.phase = phase }
        if model.caption != caption { model.caption = caption }
        if model.captionIsOwnVoice != ownVoice { model.captionIsOwnVoice = ownVoice }
        if model.captionProgress != progress { model.captionProgress = progress }
        let status = caption == Self.listeningLabel
        if model.captionIsStatus != status { model.captionIsStatus = status }
        if phase == .asleep || phase == .thinking, model.level != 0 { model.level = 0 }
    }
}
