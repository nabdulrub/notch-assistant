import Foundation

/// Decides, from loudness alone, whether someone is speaking. It is the cheap
/// first gate: speech recognition only runs while this says there is a voice,
/// which is what keeps an always-listening app light.
public struct VoiceGate: Sendable {
    public enum Transition: Equatable, Sendable {
        case started
        case ended
    }

    /// How far above the room's own noise a sound has to be to count.
    public var marginDecibels: Double = 9
    /// Nothing quieter than this is ever speech, however silent the room.
    public var minimumDecibels: Double = -52
    public var startAfter: Double = 0.1
    public var endAfter: Double = 0.7
    /// When set, a voice only counts if it starts after a moment of quiet. Used
    /// while the assistant is talking, so that a conversation already going on
    /// in the room is not taken for someone interrupting it.
    public var requiresQuietFirst = false

    public private(set) var isSpeaking = false
    public private(set) var floorDecibels: Double = -60
    private var loudFor: Double = 0
    private var quietFor: Double = 0
    private var sawQuiet = false
    private var heardFor: Double = 0
    /// The first moment after starting is spent learning how loud the room is,
    /// so a fan or an air conditioner is not taken for a voice.
    private static let warmUp: Double = 1

    public init() {}

    public static func decibels(rms: Double) -> Double {
        20 * log10(max(rms, 1e-7))
    }

    /// - Parameters:
    ///   - rms: root mean square of one buffer of samples, 0...1.
    ///   - duration: how long that buffer is, in seconds.
    public mutating func feed(rms: Double, duration: Double) -> Transition? {
        let level = VoiceGate.decibels(rms: rms)
        let warmingUp = heardFor < VoiceGate.warmUp
        heardFor += duration
        let loud = !warmingUp && level > max(floorDecibels + marginDecibels, minimumDecibels)

        if !isSpeaking {
            // The floor follows the room while nobody is talking: quickly down,
            // slowly up, so a voice does not drag it along.
            let rate = level < floorDecibels || warmingUp ? 0.2 : 0.01
            floorDecibels += (level - floorDecibels) * rate
            floorDecibels = min(max(floorDecibels, -80), -30)
        }

        if loud {
            loudFor += duration
            quietFor = 0
            if !isSpeaking, loudFor >= startAfter, sawQuiet || !requiresQuietFirst {
                isSpeaking = true
                return .started
            }
        } else {
            quietFor += duration
            loudFor = 0
            if quietFor >= 0.25 { sawQuiet = true }
            if isSpeaking, quietFor >= endAfter {
                isSpeaking = false
                return .ended
            }
        }
        return nil
    }

    public mutating func reset() {
        isSpeaking = false
        loudFor = 0
        quietFor = 0
        sawQuiet = false
    }
}
