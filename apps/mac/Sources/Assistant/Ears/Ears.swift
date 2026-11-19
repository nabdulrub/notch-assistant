import AVFoundation
import AssistantCore
import Speech

/// Microphone in, text out, all on this Mac.
///
/// The microphone stays open, but the only thing that runs all the time is a
/// loudness check. Speech recognition is opened by the conversation when it is
/// told a voice started, and it is handed the last second of audio so the first
/// word is not lost.
final class Ears: @unchecked Sendable {
    @MainActor var onVoice: ((Bool) -> Void)?
    @MainActor var onHeard: ((String) -> Void)?
    @MainActor var onEnded: ((String) -> Void)?
    @MainActor var onLevel: ((Double) -> Void)?

    private let locale: Locale
    private let contextWords: [String]
    private let engine: AVAudioEngine
    private let wantsEchoCancel: Bool
    private var configurationObserver: NSObjectProtocol?
    private var restarts: [Date] = []

    /// True when the microphone is not hearing what the app itself plays through
    /// the shared engine, which is what makes talking over it possible.
    @MainActor private(set) var cancelsEcho = false

    enum Mode {
        /// Listening normally.
        case open
        /// Dropping everything: something is playing that it would hear.
        case paused
        /// The assistant is talking and its own voice is cancelled out, so a
        /// voice now is the user talking over it. Slower to trigger, on purpose.
        case guarded
    }

    // Shared with the audio thread, under `lock`.
    private let lock = NSLock()
    private var gate = VoiceGate()
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollSeconds = 0.0
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var mode: Mode = .open
    private var monoFormat: AVAudioFormat?
    // The same audio as 24 kHz 16-bit samples, for a voice model in the cloud.
    private let streamFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var streamConverter: AVAudioConverter?
    private var streamLead: [Data] = []
    private var streamLeadBytes = 0
    private var streamSink: ((Data) -> Void)?
    /// What is kept of the audio leading up to now: at most this much, and never
    /// from before the current stretch of speech began.
    private static let streamLeadLimit = 24000 * 2 * 10
    private static let streamLeadIn = 24000
    private static let streamWakeLead = 24000 * 2 * 3
    /// As much of the speech the name was in as a voice can be learned from.
    private static let ownerLead = 24000 * 2 * 6
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    private static let prerollLimit = 1.2

    // Sessions, on the main actor.
    private final class Live {
        let id: Int
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let results: Task<String, Never>

        init(id: Int, analyzer: SpeechAnalyzer, continuation: AsyncStream<AnalyzerInput>.Continuation, results: Task<String, Never>) {
            self.id = id
            self.analyzer = analyzer
            self.continuation = continuation
            self.results = results
        }
    }

    @MainActor private var live: Live?
    @MainActor private var nextID = 0
    @MainActor private var chain: Task<Void, Never> = Task {}

    /// - Parameter engine: shared with the voice, so that what is played and what
    ///   is heard go through the same echo canceller.
    init(locale: Locale, contextWords: [String], engine: AVAudioEngine, echoCancel: Bool) {
        self.locale = locale
        self.contextWords = contextWords
        self.engine = engine
        self.wantsEchoCancel = echoCancel
    }

    private func makeTranscriber() -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
    }

    // MARK: Setup

    enum SetupError: Error, CustomStringConvertible {
        case microphoneDenied
        case localeUnsupported(String)
        case noAudioFormat
        case noInput

        var description: String {
            switch self {
            case .microphoneDenied: return "microphone access was denied"
            case .localeUnsupported(let id): return "on-device speech recognition does not support \(id)"
            case .noAudioFormat: return "speech recognition gave no audio format"
            case .noInput: return "there is no microphone to listen to"
            }
        }
    }

    /// Asks for the microphone, makes sure the on-device speech model is
    /// installed (a one-time download), and starts the loudness check.
    @MainActor
    func start(onProgress: @escaping (String) -> Void) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw SetupError.microphoneDenied }

        let transcriber = makeTranscriber()
        let supported = await SpeechTranscriber.supportedLocales
        guard supported.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw SetupError.localeUnsupported(locale.identifier)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onProgress("Getting the speech model")
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SetupError.noAudioFormat
        }
        lock.withLock { targetFormat = format }

        try startEngine()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // The input device changed (AirPods connected, a display unplugged),
            // and the engine has stopped itself.
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = Date()
                self.restarts = self.restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
                // Echo cancellation that keeps knocking the engine over is worse
                // than none.
                let giveUpOnEcho = self.restarts.count > 4
                if giveUpOnEcho { Log.write("audio keeps restarting; turning echo cancellation off") }
                do { try self.startEngine(echoCancel: self.wantsEchoCancel && !giveUpOnEcho) } catch {
                    Log.write("could not restart audio: \(error)")
                }
            }
        }
    }

    @MainActor
    private func startEngine() throws {
        try startEngine(echoCancel: wantsEchoCancel)
    }

    @MainActor
    private func startEngine(echoCancel: Bool) throws {
        engine.stop()
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if input.isVoiceProcessingEnabled != echoCancel {
            do {
                try input.setVoiceProcessingEnabled(echoCancel)
                if echoCancel {
                    // Leave the user's music and calls as loud as the system allows.
                    input.voiceProcessingOtherAudioDuckingConfiguration = AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false, duckingLevel: .min)
                }
            } catch {
                Log.write("echo cancellation unavailable: \(error.localizedDescription)")
            }
        }
        // Echo cancellation needs the output side of the engine to exist.
        _ = engine.mainMixerNode
        cancelsEcho = input.isVoiceProcessingEnabled
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SetupError.noInput }
        Log.write("microphone: \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, echo cancel \(cancelsEcho ? "on" : "off")")
        // Only the first channel is used: with voice processing on, the input can
        // arrive with extra channels that no converter will mix down.
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: 1, interleaved: false)
        lock.lock()
        monoFormat = mono
        if let targetFormat, let mono { converter = AVAudioConverter(from: mono, to: targetFormat) }
        if let mono { streamConverter = AVAudioConverter(from: mono, to: streamFormat) }
        gate.reset()
        preroll.removeAll()
        prerollSeconds = 0
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    // MARK: Audio thread

    private func process(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let channel = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        for index in 0..<frames { sum += channel[index] * channel[index] }
        let rms = Double((sum / Float(frames)).squareRoot())
        let duration = Double(frames) / buffer.format.sampleRate

        lock.lock()
        guard mode != .paused, let converter, let targetFormat, let monoFormat else {
            lock.unlock()
            return
        }
        let transition = gate.feed(rms: rms, duration: duration)
        var source = buffer
        if buffer.format.channelCount > 1, let single = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
           let destination = single.floatChannelData?[0] {
            single.frameLength = buffer.frameLength
            destination.update(from: channel, count: frames)
            source = single
        }
        if let streamConverter, let chunk = Ears.convert(source, with: streamConverter, to: streamFormat),
           let samples = chunk.int16ChannelData?[0] {
            let data = Data(bytes: samples, count: Int(chunk.frameLength) * 2)
            if let streamSink {
                streamSink(data)
            } else {
                if transition == .started {
                    // A new stretch of speech: forget what came before it.
                    while streamLeadBytes > Ears.streamLeadIn, streamLead.count > 1 { streamLeadBytes -= streamLead.removeFirst().count }
                }
                streamLead.append(data)
                streamLeadBytes += data.count
                while streamLeadBytes > Ears.streamLeadLimit, streamLead.count > 1 { streamLeadBytes -= streamLead.removeFirst().count }
            }
        }
        if let converted = Ears.convert(source, with: converter, to: targetFormat) {
            preroll.append(converted)
            prerollSeconds += duration
            while prerollSeconds > Ears.prerollLimit, preroll.count > 1 {
                let dropped = preroll.removeFirst()
                prerollSeconds -= Double(dropped.frameLength) / dropped.format.sampleRate
            }
            feed?.yield(AnalyzerInput(buffer: converted))
        }
        lock.unlock()

        // A speaking voice sits roughly between -50 and -15 dBFS.
        let level = min(max((VoiceGate.decibels(rms: rms) + 50) / 35, 0), 1)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onLevel?(level)
                if let transition { self.onVoice?(transition == .started) }
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handed {
                status.pointee = .noDataNow
                return nil
            }
            handed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Sends the microphone to `sink` as 24 kHz 16-bit samples, beginning with
    /// the speech that led up to this moment, so the words that woke it are heard.
    /// `sink` is called on the audio thread.
    ///
    /// - Parameter lead: false when nobody spoke to wake it, so there is nothing
    ///   worth catching up on.
    /// - Returns: the last few seconds heard before this, which is the speech
    ///   the name was in when a voice woke it.
    @discardableResult
    func startStreaming(lead: Bool, _ sink: @escaping (Data) -> Void) -> Data {
        lock.lock()
        defer { lock.unlock() }
        var heard = streamLead
        var bytes = streamLeadBytes
        while bytes > Ears.ownerLead, heard.count > 1 { bytes -= heard.removeFirst().count }
        let before = heard.reduce(into: Data()) { $0.append($1) }
        if lead {
            // The name is in the last few seconds; older audio is the room.
            while streamLeadBytes > Ears.streamWakeLead, streamLead.count > 1 { streamLeadBytes -= streamLead.removeFirst().count }
            streamLead.forEach(sink)
        }
        streamLead.removeAll()
        streamLeadBytes = 0
        streamSink = sink
        return before
    }

    func stopStreaming() {
        lock.withLock { streamSink = nil }
    }

    func setMode(_ new: Mode) {
        lock.lock()
        defer { lock.unlock() }
        guard new != mode else { return }
        let old = mode
        mode = new
        switch new {
        case .paused:
            gate.requiresQuietFirst = false
            clear()
        case .guarded:
            clear()
            gate.startAfter = 0.45
            gate.marginDecibels = 15
            gate.requiresQuietFirst = true
        case .open:
            gate.startAfter = 0.1
            gate.marginDecibels = 9
            gate.requiresQuietFirst = false
            // Coming out of guarded the voice it caught is still going; keep it.
            if old == .paused { clear() }
        }
    }

    /// Call with `lock` held.
    private func clear() {
        gate.reset()
        preroll.removeAll()
        prerollSeconds = 0
    }

    // MARK: Sessions

    @MainActor
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = chain
        chain = Task { @MainActor in
            await previous.value
            await work()
        }
    }

    @MainActor func startSession() { enqueue { await self.begin() } }
    @MainActor func stopSession() { enqueue { await self.end(deliver: true) } }
    @MainActor func cancelSession() { enqueue { await self.end(deliver: false) } }

    @MainActor
    private func begin() async {
        await end(deliver: false)
        nextID += 1
        let id = nextID
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextWords.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextWords
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()

        let results = Task { [weak self] () -> String in
            var finalized = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatile = ""
                    } else {
                        volatile = text
                    }
                    let running = finalized + volatile
                    await MainActor.run {
                        guard let self, self.live?.id == id else { return }
                        self.onHeard?(running)
                    }
                }
            } catch is CancellationError {
                // Dropped on purpose: speech that was not meant for the assistant.
            } catch {
                Log.write("transcription stopped: \(error)")
            }
            return finalized + volatile
        }

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            Log.write("could not start speech recognition: \(error)")
            continuation.finish()
            results.cancel()
            return
        }

        live = Live(id: id, analyzer: analyzer, continuation: continuation, results: results)
        lock.withLock {
            for buffer in preroll { continuation.yield(AnalyzerInput(buffer: buffer)) }
            feed = continuation
        }
    }

    @MainActor
    private func end(deliver: Bool) async {
        guard let current = live else {
            if deliver { onEnded?("") }
            return
        }
        lock.withLock { feed = nil }
        current.continuation.finish()
        live = nil
        if deliver {
            try? await current.analyzer.finalizeAndFinishThroughEndOfInput()
            let text = await current.results.value
            onEnded?(text)
        } else {
            await current.analyzer.cancelAndFinishNow()
            current.results.cancel()
        }
    }
}
