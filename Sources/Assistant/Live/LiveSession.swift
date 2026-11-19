import AssistantCore
import Foundation

/// One GPT-Live session over a WebSocket: microphone audio up, speech and
/// transcripts down, and the hand-offs the voice model makes when it is asked
/// for something it cannot answer itself.
@MainActor
final class LiveSession: VoiceLine {
    var onStarted: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onUserText: ((String) -> Void)?
    var onVoiceText: ((String) -> Void)?
    var onHandOff: ((String) -> Void)?
    /// Never called: this model stops talking by itself when it is talked over.
    var onCutIn: (() -> Void)?
    /// Never called: the words it recognises are checked for a goodbye instead.
    var onDismissed: (() -> Void)?
    var onEnded: ((Bool) -> Void)?

    let speaksWordForWord = false

    private let key: String
    private let voice: String
    private let instructions: String

    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var started = false
    private var closing = false
    private var ended = false
    private var waiting: [Data] = []
    private var waitingBytes = 0
    private var counter = 0
    private var seconds = 0
    // The service drops audio that arrives much faster than it was spoken, so
    // anything caught up on is let out at a little over real time.
    private var outbox: [Data] = []
    private var outboxBytes = 0
    private var sentBytes = 0
    private var paceStart = Date()
    private var paceTimer: Timer?
    private static let bytesPerSecond = 24000.0 * 2
    private static let pace = 1.15
    /// What may be sent at once. A couple of seconds went through fine; ten did not.
    private static let burst = 24000.0 * 2 * 2.2

    private static let endpoint = URL(string: "wss://api.openai.com/v1/live/sessions")!
    /// Audio held while the session is still starting. Ten seconds of it.
    private static let waitingLimit = 24000 * 2 * 10

    /// - Parameter key: the user's own OpenAI key. There is no other.
    init(key: String, voice: String, instructions: String) {
        self.key = key
        self.voice = voice
        self.instructions = instructions
    }

    func open() {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(on: task)
        send([
            "type": "session.start",
            "session": [
                "model": "gpt-live-1",
                "instructions": instructions,
                "audio": [
                    "format": ["type": "audio/pcm", "rate": 24000],
                    "output": ["voice": voice],
                ],
                // The backend is this app and the Claude session behind it.
                "delegation": ["type": "client", "acknowledgement_delay_ms": 800],
            ],
        ])
    }

    /// - Parameter pcm: mono signed 16-bit little-endian samples at 24 kHz.
    func sendAudio(_ pcm: Data) {
        guard !closing, !ended else { return }
        guard started else {
            waiting.append(pcm)
            waitingBytes += pcm.count
            while waitingBytes > Self.waitingLimit, waiting.count > 1 { waitingBytes -= waiting.removeFirst().count }
            return
        }
        outbox.append(pcm)
        outboxBytes += pcm.count
        while outboxBytes > Self.waitingLimit, outbox.count > 1 { outboxBytes -= outbox.removeFirst().count }
        drain()
    }

    private func drain() {
        guard started, !closing, !ended else { return }
        let allowed = Date().timeIntervalSince(paceStart) * Self.bytesPerSecond * Self.pace + Self.burst
        while let next = outbox.first, Double(sentBytes + next.count) <= allowed {
            outbox.removeFirst()
            outboxBytes -= next.count
            sentBytes += next.count
            send(["type": "session.input_audio.append", "audio": next.base64EncodedString()])
        }
        // Never let the allowance pile up while the room is quiet.
        let floor = Int(allowed - Self.burst)
        if outbox.isEmpty, sentBytes < floor { sentBytes = floor }
        if outbox.isEmpty {
            paceTimer?.invalidate()
            paceTimer = nil
        } else if paceTimer == nil {
            paceTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.drain() }
            }
        }
    }

    /// Something for the voice to say, in its own words.
    func say(_ text: String, handOff: String?) {
        send(["type": "session.commentary.append", "delegation_id": handOff ?? NSNull(), "content": String(text.prefix(1800))])
    }

    /// Something for the voice to know without saying it now.
    func remember(_ text: String, handOff: String?) {
        send(["type": "session.thinking.append", "delegation_id": handOff ?? NSNull(), "content": String(text.prefix(1800))])
    }

    func setMuted(_ muted: Bool) {
        send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"])
    }

    /// What is still queued to play is thrown away by the caller; the model
    /// itself needs no telling.
    func interrupt() {}

    func close() {
        guard !closing, !ended else { return }
        closing = true
        send(["type": "session.close"])
        // The final usage arrives with session.closed; do not wait for it forever.
        // Held on to until then, so the line is closed properly even though
        // nobody else is keeping this session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            MainActor.assumeIsolated { self.finish() }
        }
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        paceTimer?.invalidate()
        paceTimer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        Log.write("live session over, \(seconds)s of voice")
        onEnded?(closing)
    }

    private func send(_ event: [String: Any]) {
        guard let socket, !ended else { return }
        counter += 1
        var event = event
        event["event_id"] = "app_\(counter)"
        guard let data = try? JSONSerialization.data(withJSONObject: event), let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { Log.write("live send failed: \(error.localizedDescription)") }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.socket === task else { return }
                    switch result {
                    case .failure(let error):
                        if !self.closing { Log.write("live connection lost: \(error.localizedDescription)") }
                        self.finish()
                    case .success(let message):
                        if case .string(let text) = message { self.handle(text) }
                        self.receive(on: task)
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let event = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let type = event["type"] as? String else { return }
        switch type {
        case "session.started":
            started = true
            paceStart = Date()
            let held = waiting
            waiting.removeAll()
            waitingBytes = 0
            held.forEach(sendAudio)
            onStarted?()
        case "session.output_audio.delta":
            if let encoded = event["delta"] as? String, let bytes = Data(base64Encoded: encoded) { onAudio?(bytes) }
        case "session.input_transcript.delta":
            if let delta = event["delta"] as? String { onUserText?(delta) }
        case "session.output_transcript.delta":
            if let delta = event["delta"] as? String { onVoiceText?(delta) }
        case "session.delegation.created":
            if let id = (event["delegation"] as? [String: Any])?["id"] as? String { onHandOff?(id) }
        case "session.usage.updated", "session.closed":
            if let used = (event["usage"] as? [String: Any])?["seconds"] as? Int { seconds = used }
            if type == "session.closed" { finish() }
        case "error":
            let error = event["error"] as? [String: Any]
            Log.write("live error: \(error?["code"] as? String ?? "") \(error?["message"] as? String ?? text.prefix(200).description)")
        default:
            break
        }
    }
}
