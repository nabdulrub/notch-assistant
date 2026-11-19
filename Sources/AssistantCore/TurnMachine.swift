import Foundation

/// The conversation as a state machine: events in, effects out, no clocks, no
/// audio, no sockets. The app feeds it what the microphone, the hotkey and the
/// session report, and carries out what it asks for.
///
/// The rules it holds:
/// - Asleep, it only acts on speech that contains its name.
/// - The hotkey is the name's stand-in: press and talk.
/// - After it speaks, a short window stays open where a reply needs no name.
/// - It never talks over the user; speech that arrives while they are talking waits.
/// - A permission prompt is asked out loud and answered with a yes, a no, or a click.
public struct TurnMachine: Sendable {
    public enum TimerKind: String, Sendable {
        /// Listening, but nothing has been said yet.
        case noSpeech
        /// The window after it speaks in which no name is needed.
        case followUp
        /// It was asked something and has not answered.
        case thinking
        /// It asked for a yes or no.
        case confirm
        /// It was called by name and then nothing was said.
        case nudge
        /// The voice stopped; this is the beat it waits in case they carry on.
        case endpoint
        /// The voice never seemed to stop, but no new words have arrived.
        case stale
        /// It has something to say but someone is mid-sentence.
        case patience
    }

    public enum Event: Equatable, Sendable {
        case voiceStarted
        case voiceEnded
        case talkPressed
        case talkReleased(heldFor: Double)
        /// The running transcript of the open listening session.
        case heard(String)
        /// The final transcript, after `stopListening`.
        case utteranceEnded(String)
        case speak(String)
        case speechFinished
        /// Text pushed in without the microphone (the debug command).
        case typed(String)
        case approvalRequested(ApprovalRequest)
        /// The prompt was answered some other way: a click, or in the terminal.
        case approvalResolved(id: String)
        case timer(TimerKind)
    }

    public enum Effect: Equatable, Sendable {
        /// Open a transcription session, including the last second of audio.
        case startListening
        /// Finish the session; the answer is `utteranceEnded`.
        case stopListening
        /// Drop the session. No answer.
        case cancelListening
        case send(String)
        case say(String)
        case stopSpeaking
        case decide(ApprovalRequest, allow: Bool)
        case schedule(TimerKind, seconds: Double)
        case cancel(TimerKind)
    }

    public static let holdThreshold: Double = 0.4
    public static let followUpWindow: Double = 6
    public static let confirmWindow: Double = 9
    public static let noSpeechWindow: Double = 6
    public static let thinkingWindow: Double = 180
    /// How long after the name alone before it says it is there.
    public static let nudgeDelay: Double = 1.2
    /// How long to wait for more once words arrive after the voice has stopped.
    public static let trailingWindow: Double = 1.0
    /// Background noise can keep the microphone "hearing a voice" forever. When
    /// the words stop coming for this long, the turn is over anyway.
    public static let staleWindow: Double = 2.5
    /// How long it holds its tongue for a gap before speaking anyway.
    public static let patienceWindow: Double = 3.5

    private static let acknowledgements = ["Yeah?", "What's up?", "Yeah, I'm here.", "Mm-hm?"]

    private enum Session: Sendable {
        case none
        /// Someone is talking while it is asleep; it is checking for its name.
        case ambient
        /// It is listening on purpose.
        case active
    }

    public private(set) var phase: Phase = .asleep
    /// What it has heard of the current request, without the name.
    public private(set) var utterance = ""
    public private(set) var pendingApproval: ApprovalRequest?

    private let matcher: WakeMatcher
    private var session: Session = .none
    private var holding = false
    private var stopping = false
    private var wokeByName = false
    private var confirming = false
    private var reprompted = false
    private var queue: [String] = []
    private var voiceActive = false
    private var calledByName = false
    private var acknowledged = 0

    public init(name: String, aliases: [String] = []) {
        matcher = WakeMatcher(name: name, aliases: aliases)
    }

    public var isConfirming: Bool { confirming }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .voiceStarted: return voiceStarted()
        case .voiceEnded: return voiceEnded()
        case .talkPressed: return talkPressed()
        case .talkReleased(let heldFor): return talkReleased(heldFor: heldFor)
        case .heard(let text): return heard(text)
        case .utteranceEnded(let text): return utteranceEnded(text)
        case .speak(let text): return speak(text)
        case .speechFinished: return speechFinished()
        case .typed(let text): return typed(text)
        case .approvalRequested(let request): return approvalRequested(request)
        case .approvalResolved(let id): return approvalResolved(id: id)
        case .timer(let kind): return timer(kind)
        }
    }

    // MARK: Microphone

    private mutating func voiceStarted() -> [Effect] {
        voiceActive = true
        if phase == .speaking { return bargeIn() }
        if phase == .listening { return [.cancel(.nudge), .cancel(.noSpeech), .cancel(.endpoint)] }
        guard phase == .asleep, session == .none else { return [] }
        session = .ambient
        return [.startListening]
    }

    /// They started talking over it. Only reaches here when the microphone
    /// cannot hear the assistant's own voice.
    private mutating func bargeIn() -> [Effect] {
        queue.removeAll()
        phase = .listening
        session = .active
        holding = false
        wokeByName = false
        calledByName = false
        utterance = ""
        confirming = pendingApproval != nil
        var effects: [Effect] = [.stopSpeaking, .startListening, .schedule(.noSpeech, seconds: Self.noSpeechWindow)]
        if confirming { effects.append(.schedule(.confirm, seconds: Self.confirmWindow)) }
        return effects
    }

    private mutating func voiceEnded() -> [Effect] {
        voiceActive = false
        if phase == .asleep, session == .ambient {
            // Finish the transcript before deciding: a short "Jarvis" on its own
            // can end before the first partial result has arrived.
            guard !stopping else { return [] }
            stopping = true
            return [.stopListening]
        }
        guard phase == .listening, !holding, !stopping else { return [] }
        if !confirming, Hesitation.only(utterance) {
            // "Um", then a pause: they are still thinking.
            return [.schedule(.noSpeech, seconds: Self.noSpeechWindow)]
        }
        if utterance.isEmpty {
            // The name on its own, then a pause: keep waiting for the request,
            // and say so if the pause goes on.
            var effects: [Effect] = [.schedule(.noSpeech, seconds: Self.noSpeechWindow)]
            if calledByName, !confirming { effects.append(.schedule(.nudge, seconds: Self.nudgeDelay)) }
            return effects
        }
        if confirming {
            // A yes or a no is short; no need to wait for more.
            return [.cancel(.confirm)] + finish()
        }
        // Not done yet: give them a beat to carry on, longer if the sentence is hanging.
        return [.cancel(.noSpeech), .cancel(.stale), .schedule(.endpoint, seconds: Endpointing.grace(after: utterance))]
    }

    private mutating func finish() -> [Effect] {
        stopping = true
        return [.cancel(.noSpeech), .cancel(.nudge), .cancel(.endpoint), .cancel(.stale), .stopListening]
    }

    private mutating func heard(_ text: String) -> [Effect] {
        guard !stopping else { return [] }
        switch phase {
        case .asleep:
            guard session == .ambient, let match = matcher.match(text), match.leadsWithName else { return [] }
            phase = .listening
            session = .active
            wokeByName = true
            calledByName = true
            utterance = match.after
            return [.schedule(.noSpeech, seconds: Self.noSpeechWindow)]
        case .followUp:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            phase = .listening
            utterance = request(from: trimmed)
            var effects: [Effect] = [.cancel(.followUp)]
            if voiceActive {
                if !utterance.isEmpty { effects.append(.schedule(.stale, seconds: Self.staleWindow)) }
            } else if utterance.isEmpty || Hesitation.only(utterance) {
                effects.append(.schedule(.noSpeech, seconds: Self.noSpeechWindow))
            } else {
                // The words arrived after the voice stopped, so nothing else will end this.
                effects.append(.schedule(.endpoint, seconds: Endpointing.grace(after: utterance)))
            }
            return effects
        case .listening:
            let previous = utterance
            utterance = request(from: text)
            guard !utterance.isEmpty, utterance != previous else { return [] }
            if holding { return [.cancel(.nudge), .cancel(.noSpeech)] }
            if voiceActive { return [.cancel(.nudge), .cancel(.noSpeech), .schedule(.stale, seconds: Self.staleWindow)] }
            if confirming { return [.schedule(.confirm, seconds: Self.trailingWindow)] }
            if Hesitation.only(utterance) { return [.cancel(.nudge)] }
            return [.cancel(.nudge), .cancel(.noSpeech), .schedule(.endpoint, seconds: Endpointing.grace(after: utterance))]
        case .thinking, .speaking:
            return []
        }
    }

    private func request(from transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if wokeByName { return matcher.match(trimmed)?.after ?? utterance }
        // No name was needed, but they led with it anyway.
        if let match = matcher.match(trimmed), match.before.isEmpty { return match.after }
        return trimmed
    }

    private mutating func nextAcknowledgement() -> String {
        acknowledged += 1
        return Self.acknowledgements[(acknowledged - 1) % Self.acknowledgements.count]
    }

    private mutating func utteranceEnded(_ text: String) -> [Effect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let match = matcher.match(trimmed)

        if phase == .asleep, session == .ambient {
            stopping = false
            session = .none
            utterance = ""
            guard let match, match.leadsWithName || match.endsWithName else {
                // Not for it. If they are still talking, keep checking; if not,
                // this is the gap it was waiting for.
                guard voiceActive else { return sayNextIfWaiting() }
                session = .ambient
                return [.startListening]
            }
            if match.request.isEmpty {
                // The name and nothing else: listen for what comes next.
                phase = .listening
                session = .active
                calledByName = true
                var effects: [Effect] = [.startListening]
                if !voiceActive {
                    effects += [.schedule(.noSpeech, seconds: Self.noSpeechWindow), .schedule(.nudge, seconds: Self.nudgeDelay)]
                }
                return effects
            }
            phase = .thinking
            return [.send(match.request), .schedule(.thinking, seconds: Self.thinkingWindow)]
        }

        let request: String
        var nameAlone = false
        if wokeByName {
            request = match?.request ?? utterance
        } else if let match, match.before.isEmpty {
            // No name was needed, but they led with it anyway.
            request = match.after
            nameAlone = match.after.isEmpty
        } else {
            request = trimmed
        }
        stopping = false
        holding = false
        wokeByName = false
        calledByName = false
        session = .none
        utterance = ""

        if confirming {
            confirming = false
            return answered(request)
        }
        guard phase == .listening || phase == .followUp else { return [] }
        var effects: [Effect] = [.cancel(.noSpeech), .cancel(.followUp), .cancel(.nudge)]
        if request.isEmpty || Hesitation.only(request) {
            if nameAlone { return effects + startSaying(nextAcknowledgement()) }
            phase = .asleep
        } else {
            phase = .thinking
            effects += [.send(request), .schedule(.thinking, seconds: Self.thinkingWindow)]
        }
        return effects + sayNextIfWaiting()
    }

    // MARK: Hotkey

    private mutating func talkPressed() -> [Effect] {
        guard !stopping else { return [] }
        var effects: [Effect] = []
        switch phase {
        case .listening:
            guard !holding else { return [] }
            // Already listening: a press means "that's it, go".
            return [.cancel(.confirm)] + finish()
        case .followUp:
            phase = .listening
            holding = true
            return [.cancel(.followUp)]
        case .speaking:
            queue.removeAll()
            effects.append(.stopSpeaking)
        case .asleep, .thinking:
            break
        }
        if session != .none { effects.append(.cancelListening) }
        phase = .listening
        session = .active
        holding = true
        wokeByName = false
        calledByName = false
        utterance = ""
        confirming = pendingApproval != nil
        return effects + [.cancel(.thinking), .cancel(.followUp), .cancel(.nudge), .startListening]
    }

    private mutating func talkReleased(heldFor: Double) -> [Effect] {
        guard phase == .listening, holding, !stopping else { return [] }
        holding = false
        if heldFor >= Self.holdThreshold { return finish() }
        // A tap: keep listening until they stop talking.
        return utterance.isEmpty ? [.schedule(.noSpeech, seconds: Self.noSpeechWindow)] : []
    }

    private mutating func typed(_ text: String) -> [Effect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, phase != .listening, phase != .speaking else { return [] }
        var effects: [Effect] = [.cancel(.followUp)]
        if session != .none {
            effects.append(.cancelListening)
            session = .none
        }
        phase = .thinking
        return effects + [.send(trimmed), .schedule(.thinking, seconds: Self.thinkingWindow)]
    }

    // MARK: Speaking

    private mutating func speak(_ text: String) -> [Effect] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        switch phase {
        case .listening, .speaking:
            queue.append(trimmed)
            return []
        case .asleep, .thinking, .followUp:
            if phase == .asleep, voiceActive, session != .none {
                // Someone is mid-sentence. Wait for a gap, but not forever.
                queue.append(trimmed)
                return queue.count == 1 ? [.schedule(.patience, seconds: Self.patienceWindow)] : []
            }
            return startSaying(trimmed)
        }
    }

    private mutating func startSaying(_ text: String) -> [Effect] {
        var effects: [Effect] = [.cancel(.thinking), .cancel(.followUp), .cancel(.noSpeech), .cancel(.nudge),
                                 .cancel(.endpoint), .cancel(.stale), .cancel(.patience)]
        if session != .none {
            effects.append(.cancelListening)
            session = .none
        }
        // The microphone is dropped while it talks, so nobody counts as speaking.
        voiceActive = false
        calledByName = false
        wokeByName = false
        utterance = ""
        phase = .speaking
        return effects + [.say(text)]
    }

    private mutating func sayNextIfWaiting() -> [Effect] {
        guard !queue.isEmpty, phase != .listening, phase != .speaking else { return [] }
        return startSaying(queue.removeFirst())
    }

    private mutating func speechFinished() -> [Effect] {
        guard phase == .speaking else { return [] }
        if !queue.isEmpty {
            return [.say(queue.removeFirst())]
        }
        session = .active
        utterance = ""
        holding = false
        wokeByName = false
        if pendingApproval != nil {
            confirming = true
            phase = .listening
            return [.startListening, .schedule(.confirm, seconds: Self.confirmWindow)]
        }
        phase = .followUp
        return [.startListening, .schedule(.followUp, seconds: Self.followUpWindow)]
    }

    // MARK: Approvals

    private mutating func approvalRequested(_ request: ApprovalRequest) -> [Effect] {
        pendingApproval = request
        reprompted = false
        let prompt = ApprovalPhrase.spoken(tool: request.tool, description: request.summary, preview: request.preview)
        switch phase {
        case .listening, .speaking:
            queue.append(prompt)
            return []
        case .asleep, .thinking, .followUp:
            return startSaying(prompt)
        }
    }

    private mutating func answered(_ reply: String) -> [Effect] {
        guard let request = pendingApproval else {
            phase = .asleep
            return []
        }
        switch Confirmation.parse(reply) {
        case .yes:
            pendingApproval = nil
            phase = .thinking
            return [.cancel(.confirm), .decide(request, allow: true), .schedule(.thinking, seconds: Self.thinkingWindow)]
        case .no:
            pendingApproval = nil
            phase = .thinking
            return [.cancel(.confirm), .decide(request, allow: false), .schedule(.thinking, seconds: Self.thinkingWindow)]
        case .unclear:
            if !reply.isEmpty, !reprompted {
                reprompted = true
                return [.cancel(.confirm)] + startSaying("Wait, was that a yes or a no?")
            }
            // Still on screen; a click or the hotkey can answer it.
            phase = .asleep
            return [.cancel(.confirm)]
        }
    }

    private mutating func approvalResolved(id: String) -> [Effect] {
        guard pendingApproval?.id == id else { return [] }
        pendingApproval = nil
        var effects: [Effect] = [.cancel(.confirm)]
        if confirming {
            confirming = false
            stopping = false
            if session != .none {
                effects.append(.cancelListening)
                session = .none
            }
            phase = .thinking
            effects.append(.schedule(.thinking, seconds: Self.thinkingWindow))
        } else if phase == .speaking {
            queue.removeAll()
            effects.append(.stopSpeaking)
            phase = .thinking
            effects.append(.schedule(.thinking, seconds: Self.thinkingWindow))
        }
        return effects
    }

    // MARK: Timers

    private mutating func timer(_ kind: TimerKind) -> [Effect] {
        switch kind {
        case .noSpeech:
            guard phase == .listening, !holding, !stopping, !confirming else { return [] }
            stopping = true
            return [.stopListening]
        case .followUp:
            guard phase == .followUp, !stopping else { return [] }
            if voiceActive {
                // They started talking just as the window closed: hear them out.
                phase = .listening
                return [.schedule(.stale, seconds: Self.staleWindow)]
            }
            stopping = true
            return [.stopListening]
        case .confirm:
            guard confirming, phase == .listening, !holding, !stopping else { return [] }
            stopping = true
            return [.stopListening]
        case .patience:
            guard phase == .asleep, !queue.isEmpty else { return [] }
            return startSaying(queue.removeFirst())
        case .endpoint:
            guard phase == .listening, !holding, !stopping, !voiceActive, !utterance.isEmpty else { return [] }
            return finish()
        case .stale:
            guard phase == .listening, !holding, !stopping, !utterance.isEmpty else { return [] }
            return [.cancel(.confirm)] + finish()
        case .nudge:
            guard phase == .listening, calledByName, utterance.isEmpty,
                  !voiceActive, !holding, !stopping, !confirming else { return [] }
            return startSaying(nextAcknowledgement())
        case .thinking:
            guard phase == .thinking else { return [] }
            phase = .asleep
            return []
        }
    }
}
