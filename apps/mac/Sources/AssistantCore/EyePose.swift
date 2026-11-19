import Foundation

/// How the two eyes are drawn at one instant. Pure maths, so the character of
/// each phase can be judged without a screen.
public struct EyePose: Equatable, Sendable {
    /// 0 is shut, 1 is the resting height.
    public var openness: Double
    public var dx: Double
    public var dy: Double
    /// Width as a multiple of the resting width. Eyes spread a little as they shut.
    public var squash: Double
    /// 0...1, how strongly the eyes glow.
    public var glow: Double

    public init(openness: Double, dx: Double, dy: Double, squash: Double = 1, glow: Double = 0.3) {
        self.openness = openness
        self.dx = dx
        self.dy = dy
        self.squash = squash
        self.glow = glow
    }

    // MARK: Blinking

    /// Blinks come at uneven intervals, one per stretch of this length.
    public static let blinkPeriod: Double = 3.4

    /// 1 when open, dipping to 0 for a blink. The timing is irregular and now
    /// and then doubled, the way a real blink is, but it is a pure function of
    /// time so both eyes and every frame agree.
    public static func blink(at time: Double) -> Double {
        let slot = (time / blinkPeriod).rounded(.down)
        let within = time - slot * blinkPeriod
        let start = 0.25 + noise(slot) * (blinkPeriod - 1.1)
        var value = lid(within - start)
        if noise(slot + 0.5) < 0.24 { value = min(value, lid(within - start - 0.27)) }
        return value
    }

    /// One blink: snaps shut, rests a beat, opens a little slower.
    static func lid(_ time: Double) -> Double {
        let shut = 0.07, rest = 0.035, open = 0.16
        if time < 0 || time > shut + rest + open { return 1 }
        if time < shut {
            let progress = time / shut
            return 1 - progress * progress
        }
        if time < shut + rest { return 0 }
        let progress = (time - shut - rest) / open
        return 1 - (1 - progress) * (1 - progress)
    }

    /// A repeatable 0...1 value for a number.
    static func noise(_ value: Double) -> Double {
        let raw = sin(value * 127.1 + 311.7) * 43758.5453
        return raw - raw.rounded(.down)
    }

    // MARK: Poses

    /// The pose for a phase before blinking.
    ///
    /// - Parameters:
    ///   - level: 0...1 loudness of whoever is talking (the mic while listening,
    ///     the voice while speaking).
    ///   - gazeX: -1...1, where the pointer is relative to the island.
    ///   - gazeY: 0...1, how far below the island the pointer is.
    ///   - lookingDown: true while an approval is on screen beneath the eyes.
    public static func resting(time: Double, phase: Phase, level: Double, gazeX: Double, gazeY: Double, lookingDown: Bool) -> EyePose {
        let loud = min(max(level, 0), 1)
        // Eyes are never perfectly still: a slow breath, and a small glance away
        // every couple of seconds.
        let breath = 1 + sin(time * 1.7) * 0.018
        let glanceSlot = (time / 2.3).rounded(.down)
        let glancing = time - glanceSlot * 2.3 < 0.45 && noise(glanceSlot + 9) < 0.35
        let glance = glancing ? (noise(glanceSlot) - 0.5) * 3 : 0

        var pose: EyePose
        switch phase {
        case .asleep:
            return EyePose(openness: 0, dx: 0, dy: 0, squash: 1.25, glow: 0)
        case .listening:
            // Wide and attentive, widening a touch with the voice it hears.
            pose = EyePose(openness: (1.05 + loud * 0.15) * breath, dx: gazeX * 4 + glance, dy: gazeY * 3, glow: 0.34 + loud * 0.2)
        case .thinking:
            // Half-lidded, looking up and drifting side to side as if reading.
            pose = EyePose(openness: 0.7, dx: sin(time * 0.95) * 5 + sin(time * 2.4) * 1.1,
                           dy: -3.2 + cos(time * 0.75) * 0.9, glow: 0.24 + (sin(time * 1.9) + 1) * 0.07)
        case .speaking:
            // Bounces with its own voice and glows brighter on the loud parts.
            pose = EyePose(openness: 0.86 + loud * 0.28, dx: 0, dy: -loud * 1.6, squash: 1 + loud * 0.06, glow: 0.36 + loud * 0.5)
        case .followUp:
            pose = EyePose(openness: breath, dx: gazeX * 4 + glance, dy: gazeY * 3, glow: 0.32)
        }
        if lookingDown {
            pose.dx = 0
            pose.dy = 3
            pose.openness = min(pose.openness, 0.9)
        }
        return pose
    }

    /// The same pose with the blink applied.
    public func blinking(at time: Double) -> EyePose {
        guard openness > 0 else { return self }
        let lid = EyePose.blink(at: time)
        var pose = self
        pose.openness *= lid
        pose.squash *= 1 + (1 - lid) * 0.22
        return pose
    }

    /// Part of the way from one pose to another, eased at both ends, so a change
    /// of phase is a movement rather than a cut.
    public static func blend(_ from: EyePose, _ to: EyePose, progress: Double) -> EyePose {
        let clamped = min(max(progress, 0), 1)
        let eased = clamped * clamped * (3 - 2 * clamped)
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * eased }
        return EyePose(openness: mix(from.openness, to.openness), dx: mix(from.dx, to.dx), dy: mix(from.dy, to.dy),
                       squash: mix(from.squash, to.squash), glow: mix(from.glow, to.glow))
    }

    public static func at(time: Double, phase: Phase, level: Double, gazeX: Double, gazeY: Double, lookingDown: Bool) -> EyePose {
        resting(time: time, phase: phase, level: level, gazeX: gazeX, gazeY: gazeY, lookingDown: lookingDown).blinking(at: time)
    }
}
