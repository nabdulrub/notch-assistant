import Foundation

/// What the voice says by itself while the session is busy with a request, so a
/// hand-off is never met with silence.
public struct WaitingLines: Sendable {
    public static let acknowledgements = ["On it.", "One sec.", "Let me check.", "Okay, looking.", "Yeah, give me a sec."]
    /// Said when it is called by name and nothing is asked in the same breath.
    public static let greetings = ["Yeah?", "What's up?", "I'm here."]
    public static let stillWorking = ["Still on it.", "Still looking, hang on.", "This one's taking a minute. Still on it."]

    private var last: Int?

    public init() {}

    /// Said the moment a request is handed over. Never the same line twice running.
    public mutating func acknowledgement(pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        let lines = Self.acknowledgements
        var index = pick(lines.count) % lines.count
        if index == last { index = (index + 1) % lines.count }
        last = index
        return lines[index]
    }

    public static func greeting(pick: (Int) -> Int = { Int.random(in: 0..<$0) }) -> String {
        greetings[pick(greetings.count) % greetings.count]
    }

    /// Said when the answer is taking a while. They go in order, and the last one repeats.
    public static func stillWorking(_ said: Int) -> String {
        stillWorking[min(max(said, 0), stillWorking.count - 1)]
    }
}

/// How long the user has been left without a word since a request was handed
/// over, and whether it is time to say that the work is still going.
public struct HandOffWait: Sendable, Equatable {
    public static let firstUpdateAfter: TimeInterval = 10
    public static let nextUpdateAfter: TimeInterval = 25
    /// After this many the voice stops filling the silence. The session's own updates take over.
    public static let mostUpdates = 3

    public private(set) var updates = 0
    public private(set) var lastHeard: Date

    public init(at now: Date) {
        lastHeard = now
    }

    /// The user just heard something, whoever it came from, so the wait starts again.
    public mutating func heard(at now: Date) {
        lastHeard = now
    }

    public func updateDue(at now: Date) -> Bool {
        guard updates < Self.mostUpdates else { return false }
        return now.timeIntervalSince(lastHeard) >= (updates == 0 ? Self.firstUpdateAfter : Self.nextUpdateAfter)
    }

    public mutating func updated(at now: Date) {
        updates += 1
        lastHeard = now
    }
}
