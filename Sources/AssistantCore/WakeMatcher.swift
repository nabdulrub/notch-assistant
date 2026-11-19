import Foundation

/// Finds the assistant's name in a live transcript. This is the whole test for
/// "is this meant for me": nothing is sent anywhere until it passes.
public struct WakeMatcher: Sendable {
    public struct Match: Equatable, Sendable {
        public var before: String
        public var after: String

        /// What the user asked. Usually what follows the name ("Jarvis, how is the
        /// build"); when the name came last ("how is the build, Jarvis") it is what
        /// came before.
        public var request: String { after.isEmpty ? before : after }

        /// The name opens what they said, or opens a new sentence in it. A name
        /// in the middle of a sentence ("they all report to Jarvis") is someone
        /// talking about it, not to it.
        public var leadsWithName: Bool {
            let lead = before.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = lead.last else { return true }
            if ".?!".contains(last) { return true }
            return lead.split(separator: " ").count <= 2
        }

        /// A short request with the name tacked on the end ("how's the build, Jarvis").
        public var endsWithName: Bool {
            after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && before.split(separator: " ").count <= 8
        }
    }

    private let names: [[String]]

    /// - Parameter aliases: extra spellings speech recognition tends to produce
    ///   for the name.
    public init(name: String, aliases: [String] = []) {
        names = ([name] + aliases)
            .map { WakeMatcher.words($0).map(\.key) }
            .filter { !$0.isEmpty }
    }

    static let greetings: Set<String> = ["hey", "hi", "ok", "okay", "yo", "hello"]

    public func match(_ transcript: String) -> Match? {
        let words = WakeMatcher.words(transcript)
        guard !words.isEmpty else { return nil }
        for start in words.indices {
            for name in names where start + name.count <= words.count {
                let window = words[start..<start + name.count].map(\.key)
                guard zip(window, name).allSatisfy(WakeMatcher.sounds) else { continue }
                var beforeWords = Array(words[..<start])
                if let last = beforeWords.last, WakeMatcher.greetings.contains(last.key) {
                    beforeWords.removeLast()
                }
                let afterWords = words[(start + name.count)...]
                return Match(before: WakeMatcher.join(beforeWords), after: WakeMatcher.join(Array(afterWords)))
            }
        }
        return nil
    }

    /// A heard word counts as the name when it is the name, or one letter off for
    /// a name long enough that one letter is not half of it ("Jervis" for
    /// "Jarvis"), or the name with a possessive on the end.
    static func sounds(_ heard: String, like name: String) -> Bool {
        if heard == name { return true }
        if heard == name + "s" { return true }
        guard name.count >= 5 else { return false }
        return distance(heard, name) <= 1
    }

    struct Word {
        var key: String
        var text: String
    }

    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { raw in
            let key = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            return key.isEmpty ? nil : Word(key: key, text: String(raw))
        }
    }

    static func join(_ words: [Word]) -> String {
        let text = words.map(\.text).joined(separator: " ")
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:!?-"))
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let left = Array(a), right = Array(b)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        for i in 1...left.count {
            var current = [i] + Array(repeating: 0, count: right.count)
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[right.count]
    }
}
