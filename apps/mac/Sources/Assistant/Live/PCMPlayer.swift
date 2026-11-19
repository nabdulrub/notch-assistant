import AVFoundation
import AssistantCore

/// Plays 24 kHz PCM as it arrives, through the engine the microphone is on, so
/// the echo canceller knows what is coming out of the speaker.
@MainActor
final class PCMPlayer {
    static let sampleRate: Double = 24000

    var onLevel: ((Double) -> Void)?
    /// Called when it starts making sound and when it has run dry.
    var onPlaying: ((Bool) -> Void)?
    /// True while something audible is coming out. The voice model sends audio
    /// the whole time a session is open, silence included, so this goes by what
    /// is in the audio and when it will have been played, not by whether any is
    /// queued.
    var isPlaying: Bool { Date() < soundEndsAt }

    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: PCMPlayer.sampleRate, channels: 1, interleaved: false)!
    private var leftover = Data()
    private var endsAt = Date.distantPast
    private var soundEndsAt = Date.distantPast
    /// Quieter than this is the silence between things it says.
    private static let audible: Float = 0.004
    /// A pause this short between words is still the same stretch of talking.
    private static let hang: TimeInterval = 0.35
    private var endTimer: Timer?

    /// How much audio has been handed over but not yet played.
    var queuedSeconds: Double { max(0, endsAt.timeIntervalSinceNow) }

    init(engine: AVAudioEngine) {
        self.engine = engine
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let rms = Double((sum / Float(buffer.frameLength)).squareRoot())
            let level = min(max((VoiceGate.decibels(rms: rms) + 45) / 30, 0), 1)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isPlaying else { return }
                    self.onLevel?(level)
                }
            }
        }
    }

    /// - Parameter bytes: mono signed 16-bit little-endian samples.
    func play(_ bytes: Data) {
        leftover.append(bytes)
        let count = leftover.count / 2
        guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return }
        buffer.frameLength = AVAudioFrameCount(count)
        let output = buffer.floatChannelData![0]
        var energy: Float = 0
        leftover.withUnsafeBytes { raw in
            for index in 0..<count {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))
                output[index] = Float(sample) / 32768
                energy += output[index] * output[index]
            }
        }
        let hasSound = (energy / Float(count)).squareRoot() > Self.audible
        // A chunk can end halfway through a sample; keep the odd byte.
        leftover = Data(leftover.suffix(leftover.count - count * 2))
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            Log.write("cannot play: \(error.localizedDescription)")
            return
        }
        if !node.isPlaying { node.play() }
        node.scheduleBuffer(buffer)
        let now = Date()
        endsAt = max(endsAt, now).addingTimeInterval(Double(count) / PCMPlayer.sampleRate)
        guard hasSound else { return }
        let wasSilent = soundEndsAt <= now
        soundEndsAt = endsAt.addingTimeInterval(Self.hang)
        endTimer?.invalidate()
        endTimer = Timer.scheduledTimer(withTimeInterval: soundEndsAt.timeIntervalSince(now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.ranDry() }
        }
        if wasSilent { onPlaying?(true) }
    }

    private func ranDry() {
        endTimer = nil
        soundEndsAt = .distantPast
        onLevel?(0)
        onPlaying?(false)
    }

    /// Drops everything queued. Used when the user talks over it.
    func flush() {
        leftover = Data()
        node.stop()
        endsAt = .distantPast
        endTimer?.invalidate()
        guard isPlaying else { return }
        ranDry()
    }
}
