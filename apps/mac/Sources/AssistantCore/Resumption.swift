import Foundation

/// A line the session gave the voice to say, cut off by a sound on the
/// microphone and waiting to be picked back up.
///
/// A cut-in is not yet a request. It may be a cough, a door, or someone else in
/// the room. So the line is held: a request drops it, and quiet brings it back.
public struct HeldLine: Equatable, Sendable {
    /// What is left to say.
    public var text: String
    public var cutAt: Date
    /// Where the line is in the conversation, so it can be marked as heard after all.
    public var line: Int?

    /// The least time after the cut before it is picked up.
    public static let settle: TimeInterval = 2
    /// How long the room has to have been quiet. The voice takes a few seconds
    /// after someone stops talking to hand a request over, and a line picked up
    /// before that would be said over the request.
    public static let quiet: TimeInterval = 4
    /// In a room that never goes quiet it is picked up anyway after this long.
    public static let longestWait: TimeInterval = 10
    /// A line cut off this many times is left alone.
    public static let mostResumes = 2

    public init(text: String, cutAt: Date, line: Int? = nil) {
        self.text = text
        self.cutAt = cutAt
        self.line = line
    }

    /// - Parameters:
    ///   - lastSound: when the user, or the voice itself, was last making sound.
    ///   - busy: the user is talking, or the voice is.
    public func due(at now: Date, lastSound: Date, busy: Bool) -> Bool {
        let waited = now.timeIntervalSince(cutAt)
        guard waited >= HeldLine.settle else { return false }
        if waited >= HeldLine.longestWait { return true }
        return !busy && now.timeIntervalSince(lastSound) >= HeldLine.quiet
    }
}

public enum Resumption {
    /// What is left of a line that was cut off, from the start of the sentence
    /// the cut fell in: half a sentence heard is a sentence not heard. Empty
    /// when it was all but finished.
    ///
    /// - Parameter heardWords: how many of its words had been spoken.
    public static func rest(of text: String, heardWords: Int) -> String {
        let sentences = sentences(in: text)
        let total = sentences.reduce(0) { $0 + $1.count }
        guard total > 0, heardWords < total - 1 else { return "" }
        var before = 0
        for (index, sentence) in sentences.enumerated() {
            if heardWords < before + sentence.count {
                return sentences[index...].map { $0.joined(separator: " ") }.joined(separator: " ")
            }
            before += sentence.count
        }
        return ""
    }

    /// What is left of a line when the voice reports the part of it that had
    /// been spoken. Nil when that is not the start of this line.
    public static func rest(of text: String, heard: String) -> String? {
        let spoken = heard.split(whereSeparator: { $0.isWhitespace })
        guard !spoken.isEmpty, key(text).hasPrefix(key(heard)) else { return nil }
        // The last word may have been cut in half.
        return rest(of: text, heardWords: spoken.count - 1)
    }

    /// How many words of a line have been spoken after this long, guessed low:
    /// saying a sentence twice is better than skipping one.
    public static func wordsHeard(after seconds: TimeInterval, wordsPerSecond: Double) -> Int {
        max(0, Int(seconds * wordsPerSecond * 0.8))
    }

    /// True when what the voice has just said is the held line again: it picked
    /// the line up by itself, so the app must not say it a second time.
    public static func isSameLine(_ said: String, held: String) -> Bool {
        let said = key(said), held = key(held)
        guard said.count >= 8 else { return false }
        return held.hasSuffix(said) || said.hasSuffix(held) || held.contains(said)
    }

    static func sentences(in text: String) -> [[Substring]] {
        var all: [[Substring]] = []
        var current: [Substring] = []
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            current.append(word)
            let bare = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"')\u{201D}\u{2019}"))
            let ends = bare.hasSuffix(".") || bare.hasSuffix("?") || bare.hasSuffix("!")
            let trailsOff = bare.hasSuffix("...") || bare.hasSuffix("\u{2026}")
            if ends, !trailsOff {
                all.append(current)
                current = []
            }
        }
        if !current.isEmpty { all.append(current) }
        return all
    }

    private static func key(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
