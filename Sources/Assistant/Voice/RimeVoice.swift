import AVFoundation
import AssistantCore

/// Rime over its WebSocket v1 protocol: text goes up, 24 kHz PCM comes back in
/// pieces and is played as it arrives, so the first word is heard before the
/// sentence has finished generating.
///
/// If Rime cannot be reached, or says nothing within a few seconds, the sentence
/// is spoken by the system voice instead. It should never go silent.
@MainActor
final class RimeVoice: NSObject, Voice {
    private static let sampleRate: Double = 24000
    private static let patience: TimeInterval = 5

    private let key: String
    private let endpoint: URL
    private let speaker: String
    private let language: String
    private let fallback: SystemVoice

    private let engine: AVAudioEngine
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RimeVoice.sampleRate, channels: 1, interleaved: false)!
    private let session = URLSession(configuration: .ephemeral)
    private var socket: URLSessionWebSocketTask?
    private var socketReady = false
    private var waitingToStart: [String] = []

    private struct Turn {
        var id: String
        var text: String
        var onLevel: (Double) -> Void
        var onFinish: () -> Void
        var leftover = Data()
        var buffersPlaying = 0
        var heardAudio = false
        var generationDone = false
        var firstAudioAt: Date?
        var scheduledSeconds = 0.0
        /// When each word starts and ends, in seconds from the start, once Rime has said.
        var wordStarts: [Double] = []
        var wordEnds: [Double] = []
    }

    /// Until Rime sends real timings, the caption keeps pace at about this rate.
    private static let wordsPerSecond = 2.4

    var wordsSpoken: Int? {
        guard let current = turn else { return fallback.wordsSpoken }
        guard let began = current.firstAudioAt else { return 0 }
        let played = min(Date().timeIntervalSince(began), current.scheduledSeconds)
        if !current.wordStarts.isEmpty { return current.wordStarts.filter { $0 <= played }.count }
        return Int(played * Self.wordsPerSecond) + 1
    }

    /// Its own audio is played through the shared engine; the fallback's is not.
    var isEchoCancelled: Bool { turn != nil }

    private var turn: Turn?
    private var watchdog: Timer?

    /// - Parameter engine: the one the microphone is on, so the echo canceller
    ///   knows what is being played.
    init(key: String, speaker: String, language: String, engine: AVAudioEngine,
         endpoint: URL = URL(string: "wss://coda.api.rime.ai/ws")!, fallback: SystemVoice) {
        self.engine = engine
        self.key = key
        self.speaker = speaker.isEmpty ? "lyra" : speaker
        self.language = language.split(separator: "-").first.map(String.init) ?? "en"
        self.endpoint = endpoint
        self.fallback = fallback
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        player.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = Double((sum / Float(buffer.frameLength)).squareRoot())
            let level = min(max((VoiceGate.decibels(rms: rms) + 45) / 30, 0), 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.turn?.onLevel(level) }
            }
        }
    }

    // MARK: Voice

    func say(_ text: String, onLevel: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        stop()
        let id = UUID().uuidString
        turn = Turn(id: id, text: text, onLevel: onLevel, onFinish: onFinish)
        watchdog = Timer.scheduledTimer(withTimeInterval: Self.patience, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.giveUp(on: id, reason: "no audio in \(Int(Self.patience))s") }
        }
        do {
            if !engine.isRunning { try engine.start() }
            player.play()
        } catch {
            giveUp(on: id, reason: "audio engine: \(error.localizedDescription)")
            return
        }
        let start: [String: Any] = [
            "contextId": id,
            "start": [
                "speaker": speaker,
                "language": language,
                "text": text,
                "audioParameters": ["audioFormat": "audio/pcm", "samplingRate": Int(Self.sampleRate)],
                "timestamps": ["enable": true],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: start), let message = String(data: data, encoding: .utf8) else {
            giveUp(on: id, reason: "could not encode the request")
            return
        }
        connectIfNeeded()
        if socketReady { send(message) } else { waitingToStart = [message] }
    }

    @discardableResult
    func stop() -> SpokenPortion? {
        let fromFallback = fallback.stop()
        watchdog?.invalidate()
        watchdog = nil
        guard let current = turn else { return fromFallback }
        turn = nil
        waitingToStart.removeAll()
        if socketReady { send(#"{"contextId":"\#(current.id)","cancel":{}}"#) }
        player.stop()
        current.onLevel(0)
        return Self.portion(of: current)
    }

    /// How much of it had come out of the speaker. Exact when Rime has sent word
    /// timings, otherwise judged from how long it had been playing.
    private static func portion(of turn: Turn) -> SpokenPortion {
        let words = turn.text.split(separator: " ").map(String.init)
        let played = min(turn.firstAudioAt.map { Date().timeIntervalSince($0) } ?? 0, turn.scheduledSeconds)
        var count: Int
        if !turn.wordEnds.isEmpty {
            count = turn.wordEnds.filter { $0 <= played }.count
        } else {
            let whole = turn.generationDone ? turn.scheduledSeconds : max(turn.scheduledSeconds, Double(words.count) / 2.6)
            count = Int(Double(words.count) * played / max(whole, 0.1))
        }
        count = min(max(count, 0), words.count)
        return SpokenPortion(heard: words.prefix(count).joined(separator: " "),
                             missed: words.dropFirst(count).joined(separator: " "))
    }

    // MARK: Socket

    private func connectIfNeeded() {
        guard socket == nil else { return }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let task = session.webSocketTask(with: request)
        socket = task
        socketReady = false
        task.resume()
        receive(on: task)
    }

    private func send(_ message: String) {
        socket?.send(.string(message)) { error in
            if let error { Log.write("rime send failed: \(error.localizedDescription)") }
        }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.socket === task else { return }
                    switch result {
                    case .failure(let error):
                        self.socket = nil
                        self.socketReady = false
                        if let id = self.turn?.id, self.turn?.generationDone == false {
                            self.giveUp(on: id, reason: "connection: \(error.localizedDescription)")
                        }
                    case .success(let message):
                        if case .string(let text) = message { self.handle(text) }
                        self.receive(on: task)
                    }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        if object["ready"] != nil {
            socketReady = true
            waitingToStart.forEach(send)
            waitingToStart.removeAll()
            return
        }
        let context = object["contextId"] as? String
        if let error = object["error"] as? [String: Any] {
            let detail = "\(error["kind"] as? String ?? "error"): \(error["message"] as? String ?? "")"
            if let id = turn?.id, context == nil || context == id || context?.isEmpty == true {
                giveUp(on: id, reason: detail)
            } else {
                Log.write("rime \(detail)")
            }
            return
        }
        guard let id = turn?.id, context == id else { return }
        if let encoded = Self.audioString(object["audio"]), let bytes = Data(base64Encoded: encoded) {
            play(bytes)
        } else if let done = object["done"] {
            if let spans = ((done as? [String: Any])?["timestamps"] as? [String: Any])?["spans"] as? [[String: Any]] {
                func seconds(_ key: String) -> [Double] {
                    spans.compactMap { span in
                        (span[key] as? String).flatMap { Double($0.replacingOccurrences(of: "s", with: "")) }
                    }
                }
                turn?.wordStarts = seconds("start")
                turn?.wordEnds = seconds("end")
            }
            turn?.generationDone = true
            finishIfPlayedOut()
        }
    }

    private static func audioString(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let wrapped = value as? [String: Any] {
            return (wrapped["audio"] ?? wrapped["data"] ?? wrapped["chunk"]) as? String
        }
        return nil
    }

    // MARK: Playback

    private func play(_ bytes: Data) {
        guard var current = turn else { return }
        current.leftover.append(bytes)
        let sampleCount = current.leftover.count / 2
        guard sampleCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            turn = current
            return
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        let output = buffer.floatChannelData![0]
        current.leftover.withUnsafeBytes { raw in
            for index in 0..<sampleCount {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                output[index] = Float(sample) / 32768
            }
        }
        // PCM chunks can end halfway through a sample; keep the odd byte.
        current.leftover = current.leftover.suffix(current.leftover.count - sampleCount * 2)
        current.scheduledSeconds += Double(sampleCount) / Self.sampleRate
        if !current.heardAudio {
            current.firstAudioAt = Date()
            current.heardAudio = true
            watchdog?.invalidate()
            watchdog = nil
        }
        current.buffersPlaying += 1
        let id = current.id
        turn = current
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.turn?.id == id else { return }
                    self.turn?.buffersPlaying -= 1
                    self.finishIfPlayedOut()
                }
            }
        }
    }

    private func finishIfPlayedOut() {
        guard let current = turn, current.generationDone, current.buffersPlaying == 0 else { return }
        turn = nil
        watchdog?.invalidate()
        watchdog = nil
        current.onLevel(0)
        current.onFinish()
    }

    private func giveUp(on id: String, reason: String) {
        guard let current = turn, current.id == id else { return }
        Log.write("rime gave up (\(reason))" + (current.heardAudio ? "" : ", using the system voice"))
        turn = nil
        watchdog?.invalidate()
        watchdog = nil
        player.stop()
        if current.heardAudio {
            // Part of it was already said; saying it again would be worse.
            current.onLevel(0)
            current.onFinish()
        } else {
            fallback.say(current.text, onLevel: current.onLevel, onFinish: current.onFinish)
        }
    }
}
