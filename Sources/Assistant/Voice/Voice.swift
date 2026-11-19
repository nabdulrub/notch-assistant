import AVFoundation
import AssistantCore

/// Whatever turns text into sound. Rime is one of these; so is the Mac's own
/// voice, which needs no key and no network.
@MainActor
protocol Voice: AnyObject {
    /// Speaks `text`. `onLevel` gets a 0...1 loudness while it talks, for the eyes.
    /// `onFinish` is called once when it has said everything; it is not called
    /// when the speech is cut off with `stop`.
    func say(_ text: String, onLevel: @escaping (Double) -> Void, onFinish: @escaping () -> Void)
    /// Cuts it off. Returns how far it got, or nil when it was not speaking.
    @discardableResult func stop() -> SpokenPortion?
    /// True when what it is saying right now goes through the shared engine, so
    /// the microphone does not hear it and the user can talk over it.
    var isEchoCancelled: Bool { get }
    /// How many words of the current sentence have started coming out, for the
    /// caption that follows along. Nil when it is not speaking.
    var wordsSpoken: Int? { get }
}

/// Where a sentence was cut off.
struct SpokenPortion: Equatable {
    var heard: String
    var missed: String
}

/// The built-in voice. Picks the best English voice installed on the Mac.
@MainActor
final class SystemVoice: NSObject, Voice, @preconcurrency AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var onLevel: ((Double) -> Void)?
    private var onFinish: (() -> Void)?
    private var current: AVSpeechUtterance?
    private var level = 0.0
    private var meter: Timer?
    private var spokenUpTo = 0

    var isEchoCancelled: Bool { false }

    var wordsSpoken: Int? {
        guard let utterance = current else { return nil }
        let text = utterance.speechString as NSString
        let said = text.substring(to: min(spokenUpTo, text.length))
        return said.split(separator: " ").count + 1
    }

    override init() {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let best = english
            .filter { $0.quality == .premium || $0.quality == .enhanced }
            .max { ($0.quality.rawValue, $0.language == "en-US" ? 1 : 0) < ($1.quality.rawValue, $1.language == "en-US" ? 1 : 0) }
        voice = best ?? AVSpeechSynthesisVoice(language: "en-US")
        super.init()
        synthesizer.delegate = self
    }

    var voiceName: String { voice?.name ?? "default" }

    func say(_ text: String, onLevel: @escaping (Double) -> Void, onFinish: @escaping () -> Void) {
        stop()
        let utterance = AVSpeechUtterance(string: SpokenText.plain(text))
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        current = utterance
        spokenUpTo = 0
        self.onLevel = onLevel
        self.onFinish = onFinish
        level = 0.5
        meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.level *= 0.88
                self.onLevel?(self.level)
            }
        }
        synthesizer.speak(utterance)
    }

    @discardableResult
    func stop() -> SpokenPortion? {
        guard let utterance = current else { return nil }
        let text = utterance.speechString as NSString
        let cut = min(spokenUpTo, text.length)
        let portion = SpokenPortion(
            heard: text.substring(to: cut).trimmingCharacters(in: .whitespaces),
            missed: text.substring(from: cut).trimmingCharacters(in: .whitespaces))
        current = nil
        onFinish = nil
        finishMeter()
        synthesizer.stopSpeaking(at: .immediate)
        return portion
    }

    private func finishMeter() {
        meter?.invalidate()
        meter = nil
        onLevel?(0)
        onLevel = nil
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        // The word it is starting on has not been heard yet.
        spokenUpTo = characterRange.location
        level = 0.9
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        finishMeter()
        let done = onFinish
        onFinish = nil
        done?()
    }
}
