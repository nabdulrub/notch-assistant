import AssistantCore
import Foundation

/// One conversation with the model that runs on this Mac, through the bridge
/// in `sophon_bridge.py`. Raw audio goes both ways; everything else is a line
/// of JSON. Nothing here leaves the machine.
@MainActor
final class SophonSession: VoiceLine {
    var onStarted: (() -> Void)?
    var onAudio: ((Data) -> Void)?
    var onUserText: ((String) -> Void)?
    var onVoiceText: ((String) -> Void)?
    var onHandOff: ((String) -> Void)?
    var onCutIn: (() -> Void)?
    var onCutHeard: ((String) -> Void)?
    var onNothingAsked: (() -> Void)?
    var onDismissed: (() -> Void)?
    var onEnded: ((Bool) -> Void)?

    let speaksWordForWord = true

    private let port: Int
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var started = false
    private var closing = false
    private var ended = false
    private var muted = false
    private var waiting: [Data] = []
    private var waitingBytes = 0
    /// What it has said of its current reply, to tell new words from old.
    private var shown = ""
    private let openedAt = Date()

    /// Audio held while the connection is still opening. Ten seconds of it.
    private static let waitingLimit = 24000 * 2 * 10

    init(port: Int) {
        self.port = port
    }

    func open() {
        guard let url = URL(string: "ws://127.0.0.1:\(port)") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = session.webSocketTask(with: request)
        socket = task
        task.resume()
        receive(on: task)
    }

    func sendAudio(_ pcm: Data) {
        guard !closing, !ended, !muted else { return }
        guard started else {
            waiting.append(pcm)
            waitingBytes += pcm.count
            while waitingBytes > Self.waitingLimit, waiting.count > 1 { waitingBytes -= waiting.removeFirst().count }
            return
        }
        socket?.send(.data(pcm)) { _ in }
    }

    func say(_ text: String, handOff: String?) {
        send(["type": "say", "text": String(text.prefix(1800)), "id": handOff ?? ""])
    }

    /// The model keeps only what it heard and said itself, so there is nowhere
    /// to put this. The session behind it is what remembers.
    func remember(_ text: String, handOff: String?) {}

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    func interrupt() {
        send(["type": "interrupt"])
    }

    func close() {
        guard !closing, !ended else { return }
        closing = true
        finish()
    }

    private func finish() {
        guard !ended else { return }
        ended = true
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        Log.write("line to the model on this Mac closed after \(Int(Date().timeIntervalSince(openedAt)))s")
        onEnded?(closing)
    }

    private func send(_ event: [String: Any]) {
        guard let socket, !ended, let data = try? JSONSerialization.data(withJSONObject: event),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { error in
            if let error { Log.write("could not reach the model on this Mac: \(error.localizedDescription)") }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.socket === task else { return }
                    switch result {
                    case .failure(let error):
                        if !self.closing {
                            Log.write(self.started
                                ? "lost the model on this Mac: \(error.localizedDescription)"
                                : "the model on this Mac is not answering yet; it takes a few seconds to load after the app starts")
                        }
                        self.finish()
                    case .success(let message):
                        switch message {
                        case .data(let audio): self.onAudio?(audio)
                        case .string(let text): self.handle(text)
                        @unknown default: break
                        }
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
        case "ready":
            started = true
            let held = waiting
            waiting.removeAll()
            waitingBytes = 0
            held.forEach(sendAudio)
            onStarted?()
        case "voice_text":
            guard let all = event["text"] as? String else { return }
            if event["given"] != nil {
                // Words it was handed to say arrive whole.
                onVoiceText?(" " + all)
                shown = ""
            } else if all.hasPrefix(shown), !shown.isEmpty {
                onVoiceText?(String(all.dropFirst(shown.count)))
                shown = all
            } else {
                onVoiceText?(" " + all)
                shown = all
            }
        case "handoff":
            guard let id = event["id"] as? String, let request = event["request"] as? String else { return }
            // This model gives no words for what the user says; its own
            // summary of the request is the nearest thing there is.
            onUserText?(request)
            onHandOff?(id)
        case "unheard":
            Log.write("kept quiet instead of saying: \(event["text"] as? String ?? "")")
        case "cut":
            if let said = event["said"] as? String { onCutHeard?(said) }
        case "silent":
            Log.write("the voice stayed out of it")
            onNothingAsked?()
        case "goodbye":
            onDismissed?()
        case "interrupt":
            shown = ""
            onCutIn?()
        case "error":
            Log.write("the model on this Mac reported: \(event["message"] as? String ?? text.prefix(200).description)")
        default:
            break
        }
    }
}
