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
    /// Set from the moment a request is handed over until the session has dealt
    /// with it, so the silence in between can be filled.
    private var wait: HandOffWait?
    private var waitingLines = WaitingLines()
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
    /// The last thing the session gave the voice to say, and how often it has
    /// been picked back up after a cut-in.
    private var given: (text: String, at: Date, resumes: Int)?
    /// A line of the session's that a sound cut off, waiting to be picked back up.
    private var held: HeldLine?
    /// What the voice said it had spoken when it was last cut off.
    private var cutHeard: (text: String, at: Date)?
    private var lastTalkingAt = Date.distantPast
    /// Which of its lines the caption is following, and since when.
    private var following: (index: Int, since: Date)?
    private var displayTimer: Timer?
    private var idleTimer: Timer?
    private var checkingForName = false
    /// Set when the name turns up in a sentence that is still being said, for a
    /// voice whose requests are read from the Mac's own transcription.
    private var nameHeardAt: Date?
    /// The longest a sentence is heard out after the name before it is taken as it stands.
    private static let longestRequest: TimeInterval = 12
    private var userTalking = false
    private var sessionBusy = false
    private var note: String?
    /// True while the screen is being shown to the session, and briefly after.
    private var looking = false
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
        bridge.onLook = { [weak self] requestId, answer in self?.look(requestId, answer: answer) }
        bridge.onSessionCount = { count in Log.write(count > 0 ? "session attached" : "session detached") }
        model.onDismiss = { [weak self] in self?.dismiss(how: "a click on the notch") }
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
                self.wait = nil
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
            if self.readsRequestsItself {
                // Hear the sentence out: what follows the name is the request.
                if self.nameHeardAt == nil {
                    self.nameHeardAt = Date()
                    self.refresh()
                }
                return
            }
            self.wake("heard its name", byVoice: true)
        }
        ears.onEnded = { [weak self] text in
            guard let self else { return }
            self.checkingForName = false
            guard self.state == .asleep else { return }
            let named = self.nameHeardAt != nil
            self.nameHeardAt = nil
            if let match = self.matcher.match(text), match.leadsWithName || match.endsWithName {
                let request = self.readsRequestsItself ? match.requestInTheSameBreath : nil
                if let request, Dismissal.matches(request) {
                    // Told to go away while already asleep.
                    self.refresh()
                } else {
                    self.wake("heard its name", byVoice: true, request: request)
                }
            } else if named {
                // The name was there while they spoke and the finished words lost it.
                self.wake("heard its name", byVoice: true)
            } else if !text.isEmpty {
                let words = text.split(separator: " ").count
                Log.write(words <= 3 ? "overheard, no name: \(text)" : "overheard \(words) words, no name")
            }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkWaiting()
                self?.checkHeld()
                self?.checkNameHeard()
                self?.checkIdle()
            }
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

    /// The small model on this Mac is handed the words that woke it as a clipped
    /// burst and often cannot make them out, while the Mac's own transcription
    /// has just heard them well enough to find the name. So for that voice, a
    /// request said along with the name is read from the transcription.
    private var readsRequestsItself: Bool { settings.voiceEngine == "sophon" }

    /// A sentence that never seems to end, in a loud room, is taken as it stands.
    private func checkNameHeard() {
        guard state == .asleep, let since = nameHeardAt, Date().timeIntervalSince(since) > Self.longestRequest else { return }
        checkingForName = false
        ears.stopSession()
    }

    /// - Parameter request: what was asked in the same breath as the name, when
    ///   the transcription is trusted with it. It goes straight to the session.
    private func wake(_ why: String, byVoice: Bool = false, request: String? = nil) {
        guard state == .asleep else { return }
        nameHeardAt = nil
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
            if let request { self.take(request) }
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
            // They said something: what was cut off stays cut off.
            self.held = nil
            if let said = self.dialogue.latest(.user)?.text, Dismissal.matches(said) {
                self.wait = nil
            self.sleep("told to stop")
                return
            }
            self.collectAnswer(text)
            self.refresh()
        }
        session.onVoiceText = { [weak self, weak session] text in
            guard let self, self.session === session else { return }
            // The voice picking its line up by itself is not said a second time.
            if let held = self.held, Resumption.isSameLine(text, held: held.text) { self.held = nil }
            self.dialogue.append(.voice, text)
            self.logFinishedLines()
            self.lastEngaged = Date()
            self.wait?.heard(at: Date())
            self.relay.spoke()
            self.refresh()
        }
        session.onHandOff = { [weak self, weak session] id in
            guard let self, self.session === session else { return }
            self.openHandOff = id
            self.lastEngaged = Date()
            self.held = nil
            self.acknowledge(id, on: session)
            self.refresh()
            // The hand-off carries no words, and the transcript trails the audio.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                MainActor.assumeIsolated { self?.handOver(id) }
            }
        }
        session.onCutIn = { [weak self, weak session] in
            guard let self, self.session === session else { return }
            if self.player.isPlaying {
                self.dialogue.markCutOff()
                self.hold()
            }
            self.player.flush()
            self.refresh()
        }
        session.onCutHeard = { [weak self, weak session] said in
            guard let self, self.session === session else { return }
            self.cutHeard = (said, Date())
            // The cut-in itself may have come first, with only a guess at how far it got.
            if let held = self.held, Date().timeIntervalSince(held.cutAt) < 1, let given = self.given,
               let rest = Resumption.rest(of: given.text, heard: said) {
                if rest.isEmpty { self.held = nil } else { self.held?.text = rest }
            }
        }
        session.onNothingAsked = { [weak self, weak session] in
            guard let self, self.session === session, let held = self.held, !self.player.isPlaying else { return }
            // What cut it off was not a request.
            self.pickUp(held)
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
        // With the request already in hand, the voice model is not given the
        // same words to answer a second time.
        ears.startStreaming(lead: byVoice && request == nil) { [weak session] data in
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
        held = nil
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

    /// The moment a request is handed over, the user hears that it was taken. A
    /// voice that retells what it is given says so itself; one that speaks word
    /// for word hands over without a sound, so the line is given to it.
    private func acknowledge(_ id: String, on session: VoiceLine?) {
        let now = Date()
        wait = HandOffWait(at: now)
        guard let session, session.speaksWordForWord else { return }
        // It may have said something of its own on the way to the hand-off.
        if player.isPlaying || now.timeIntervalSince(lastPlayedAt) < 1.5 { return }
        let line = waitingLines.acknowledgement()
        Log.write("acknowledging: \(line)")
        session.say(line, handOff: id)
    }

    /// While the session is still on a request and the user has heard nothing
    /// for a while, say that the work is still going. Never over the user, and
    /// never while it is waiting for a yes or a no.
    private func checkWaiting() {
        guard var waiting = wait else { return }
        let now = Date()
        if player.isPlaying {
            waiting.heard(at: now)
            wait = waiting
            return
        }
        guard model.approval == nil, !userTalking, now.timeIntervalSince(lastWords) > 2, waiting.updateDue(at: now) else { return }
        let line = WaitingLines.stillWorking(waiting.updates)
        waiting.updated(at: now)
        wait = waiting
        Log.write("still waiting on the session: \(line)")
        say(line)
    }

    /// A sound cut off something the session gave the voice to say. It is kept:
    /// a cough is not a request. What they went on to say drops it, and so
    /// does sending the assistant away; quiet brings it back.
    private func hold() {
        guard let given, let session, Date().timeIntervalSince(given.at) < 40, given.resumes < HeldLine.mostResumes else { return }
        let now = Date()
        var rest = given.text
        var index: Int?
        if session.speaksWordForWord {
            // Only when that line is the one being spoken, and from the
            // sentence the cut fell in.
            guard let line = dialogue.latest(.voice), let found = line.text.range(of: given.text) else { return }
            index = line.index
            let before = line.text[..<found.lowerBound].split(whereSeparator: { $0.isWhitespace }).count
            let started = following?.index == line.index ? following?.since : playingSince
            let spoken = Resumption.wordsHeard(after: now.timeIntervalSince(started ?? now), wordsPerSecond: Self.readingPace)
            rest = Resumption.rest(of: given.text, heardWords: max(0, spoken - before))
            // The voice's own word for how far it got beats the guess.
            if let heard = cutHeard, now.timeIntervalSince(heard.at) < 1, let exact = Resumption.rest(of: given.text, heard: heard.text) {
                rest = exact
            }
        }
        guard !rest.isEmpty else { return }
        held = HeldLine(text: rest, cutAt: now, line: index)
        Log.write("cut off by a sound; holding the rest of the line")
    }

    /// Picks a held line back up once it is clear that nothing was asked.
    private func checkHeld() {
        guard let held, state == .awake, session != nil else { return }
        let now = Date()
        let busy = userTalking || player.isPlaying
        guard held.due(at: now, lastSound: max(lastTalkingAt, lastPlayedAt), busy: busy), !player.isPlaying else { return }
        pickUp(held)
    }

    private func pickUp(_ line: HeldLine) {
        guard let session else { return }
        held = nil
        if let index = line.line { dialogue.heardAfterAll(index) }
        given = (line.text, Date(), (given?.resumes ?? 0) + 1)
        lastEngaged = Date()
        Log.write("picking the line back up: \(line.text)")
        session.say(session.speaksWordForWord ? line.text : "A noise cut you off before you finished. Say this again: " + line.text,
                    handOff: openHandOff)
    }

    /// Sends it back to sleep without a word: a click on the notch, or the menu.
    /// Saying bye depends on the voice model catching it, and this does not.
    func dismiss(how: String) {
        guard state != .asleep else { return }
        if player.isPlaying {
            session?.interrupt()
            player.flush()
            dialogue.markCutOff()
        }
        wait = nil
        sleep("sent away with \(how)")
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
                held = nil
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
        if userTalking || speaking { lastTalkingAt = Date() }
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

    /// A request read from the Mac's transcription, handed over without the voice
    /// model having to understand it.
    private func take(_ request: String) {
        Log.write("heard with the name: \(request)")
        dialogue.append(.user, request)
        logFinishedLines()
        let id = "heard-" + UUID().uuidString.prefix(8).lowercased()
        openHandOff = id
        lastEngaged = Date()
        acknowledge(id, on: session)
        handOver(id)
    }

    private func handOver(_ id: String) {
        guard openHandOff == id else { return }
        let said = dialogue.rendered(from: handedOver, voiceName: settings.assistantName)
        handedOver = dialogue.lines.count
        Log.write("handing over:\n\(said)")
        let message = "The voice handed this to you. What has been said since you were last asked:\n\(said)"
        if !bridge.send(.utterance(message, source: "voice")) {
            Log.write("no session attached")
            wait = nil
            session?.say(session?.speaksWordForWord == true
                ? "I'm not hooked up to a Claude session right now."
                : "Tell them you are not hooked up to a Claude session right now.", handOff: id)
        }
    }

    private static let lookingLabel = "Looking at your screen"

    /// The session asked to see the screen. The notch says so for as long as it
    /// takes and a moment after, so a look never goes unnoticed.
    private func look(_ requestId: String, answer: @escaping @Sendable (BridgeMessage) -> Void) {
        Log.write("the session asked to see the screen")
        note = Self.lookingLabel
        looking = true
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
            guard let self else { return }
            self.looking = false
            if self.note == Self.lookingLabel { self.note = nil }
            self.refresh()
        }
    }

    private func received(_ message: BridgeMessage) {
        switch message.type {
        case .speak:
            let text = (message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            Log.write("to say: \(text)")
            relay.spoke()
            // Mid-turn this is an update and the wait goes on. Where the session
            // cannot be seen working, its first word is taken as the answer.
            if sessionBusy { wait?.heard(at: Date()) } else { wait = nil }
            // Something cut off and still held is finished before the next thing.
            if let line = held { pickUp(line) }
            given = (text, Date(), 0)
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
            if let question = pendingQuestion { given = (question, Date(), 0) }
            say(pendingQuestion ?? "")
            refresh()
        case .utterance:
            // Typed in from the command line, for testing without a microphone.
            bridge.send(.utterance(message.text ?? "", source: "typed"))
        case .nudge:
            relay.lookNow()
        case .hello, .event, .permissionVerdict, .look, .screen:
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
            if nameHeardAt != nil {
                // Its name was said and the sentence is still going.
                phase = .listening
                caption = Self.listeningLabel
            } else {
                phase = sessionBusy ? .thinking : .asleep
                if sessionBusy { caption = note ?? "Working on it" }
            }
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
        // A look at the screen is always said, whatever else is going on, short
        // of the assistant's own words.
        if looking, phase != .speaking {
            phase = .thinking
            caption = Self.lookingLabel
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
