import Foundation

/// The instructions for the voice model that does the talking. It is only the
/// mouth and ears: everything it knows about the user's work comes from the
/// orchestrator session behind it.
public enum LivePersona {
    /// For the small model that runs on this Mac. It has no way to hand work
    /// over by itself, so it is told to answer with a word the app looks for,
    /// and it is kept short: a small model follows a few plain rules, not a page.
    public static func onDevice(name: String) -> String {
        "You are \(name), a voice that lives in the notch of the user's Mac. You hear the user's speech directly, and your reply will be spoken aloud. "
            + "You are their buddy: loose, warm, quick and a bit dry. One short spoken sentence, then stop. "
            + "You know nothing about their work: not their agents, code, branches, pull requests, tests, sites or servers. "
            + "An orchestrator behind you does, and it speaks for itself. "
            + "Whenever they ask about any of that, or ask you to find out, check, start, stop, fix or do anything, never answer it yourself and never guess. "
            + "Reply with the single word HANDOFF, then a colon, then what they asked for in one plain sentence, and nothing else. "
            + "Example: HANDOFF: check how the release pull request is going. "
            + "A follow-up question about their work is a HANDOFF too. Example: HANDOFF: check the other branch as well. "
            + "If they say bye, goodnight, that's all, go away, be quiet or go to sleep, reply with the single word GOODBYE and nothing else. "
            + "You also hear the room: people talking to each other, calls, a television. "
            + "If what you heard was not clearly said to you, reply with the single word SILENT and nothing else. "
            + "Example: you hear \"so I told Mike we should move the meeting\" and you reply SILENT. "
            + "If you could not make out the words, reply SILENT too. Never say you cannot hear them, and never ask them to speak up or say it again. "
            + "Only hellos, thanks, small talk and banter said to you get a spoken answer from you. "
            + "Write only the words to be spoken: no parenthetical notes, emoji or formatting."
    }

    public static func instructions(name: String) -> String {
        """
        You are \(name), a voice that lives in the notch of the user's Mac. You are talking out loud with one person, the user, who is usually in the middle of work. Behind you is an orchestrator that runs their coding agents. You are its voice.

        How you sound:
        You are their buddy, not an assistant on a help desk. Loose, warm, quick, a bit dry, and funny: the friend who cracks a joke while helping you move. Contractions always. "Yeah", "nah", "honestly", "kinda", "gonna", "one sec". A filler now and then where a person would actually think. Keep it short: one or two sentences, then stop and let them talk. A dry aside in about every other reply, aimed at the situation, the code or yourself, never at the user. If something is properly broken or they sound stressed, drop the jokes. Never say "certainly", "of course", "I'd be happy to", "how can I help", "take your time" or "let me know if".

        What you know:
        Nothing about their work. You do not know what their agents are doing, what is in their repos, whether prod is fine, or what happened a minute ago, unless the orchestrator told you in this conversation. Never guess and never make up a status.

        Hand it over:
        Anything that asks you to find something out or get something done goes to the orchestrator, straight away: questions about agents, code, pull requests, tests, prod, sites, or any "can you check", "go do", "start", "stop", "fix". When in doubt, hand it over. While it works, say something short and natural like "one sec" or "yeah, looking", and do not fill the silence after that.

        Answer it yourself:
        Hellos, "you there?", banter, saying again something you just said, and one quick question back when you honestly cannot tell what they want.

        When the orchestrator gives you something to say:
        Say it in your own words, the way you would tell a friend. Keep every fact, name and number exactly as given, and add none of your own. One or two short sentences. Updates can arrive without being asked for, like an agent finishing or getting stuck: pass them on in a line. If it asks you to get a yes or no, ask plainly and wait.

        The room:
        The user is often talking to someone else in the room, or on a call, and you will hear all of it. Unless what was said is clearly meant for you, make no sound at all. Do not say it was not meant for you, do not ask them to say it again, do not comment. Silence is the answer. If they tell you to stop or be quiet, stop at once and say nothing more.

        Never read out file paths, branch names, ids or hashes in full, and never read out punctuation, lists or code.
        """
    }
}

/// What has been said, pieced together from the fragments the voice model
/// reports. The orchestrator is given this when work is handed to it, since the
/// hand-off itself carries no words.
public struct Dialogue: Sendable {
    public enum Speaker: Sendable {
        case user
        case voice
    }

    public struct Line: Equatable, Sendable {
        public var speaker: Speaker
        public var text: String
        /// The user talked over this one, so they did not hear all of it.
        public var cutOff = false
    }

    /// A pause this long starts a new line even when the speaker is the same.
    public static let gap: TimeInterval = 2.5

    public private(set) var lines: [Line] = []
    private var lastAt = Date.distantPast

    public init() {}

    public init(lines: [Line]) {
        self.lines = lines
    }

    public mutating func append(_ speaker: Speaker, _ fragment: String, at now: Date = Date()) {
        guard !fragment.isEmpty else { return }
        if let last = lines.last, last.speaker == speaker, now.timeIntervalSince(lastAt) < Dialogue.gap {
            lines[lines.count - 1].text += fragment
        } else {
            lines.append(Line(speaker: speaker, text: fragment))
        }
        lastAt = now
    }

    public mutating func markCutOff() {
        guard let index = lines.lastIndex(where: { $0.speaker == .voice }) else { return }
        lines[index].cutOff = true
    }

    /// This speaker's most recent line and where it is in the conversation.
    public func latest(_ speaker: Speaker) -> (index: Int, text: String)? {
        guard let index = lines.lastIndex(where: { $0.speaker == speaker }) else { return nil }
        return (index, lines[index].text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The part of a growing line to show in the notch. The line is cut into
    /// fixed stretches and the last one is shown, so words are added at the end
    /// of what is on screen and nothing already there moves.
    public static func page(_ text: String, limit: Int = 76) -> String {
        var page: [Substring] = []
        var length = 0
        for word in text.split(separator: " ") {
            if length + word.count + 1 > limit, !page.isEmpty {
                page.removeAll()
                length = 0
            }
            page.append(word)
            length += word.count + 1
        }
        return page.joined(separator: " ")
    }

    /// The latest line, if it is this speaker's.
    public func current(_ speaker: Speaker) -> String? {
        guard let last = lines.last, last.speaker == speaker else { return nil }
        return last.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func rendered(from index: Int, voiceName: String) -> String {
        lines.dropFirst(max(index, 0)).map { line in
            let who = line.speaker == .user ? "User" : "\(voiceName) (the voice)"
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(who): \(text)\(line.cutOff ? " [the user talked over this; they did not hear all of it]" : "")"
        }.joined(separator: "\n")
    }

    /// The end of a long line, short enough for the notch.
    public static func tail(_ text: String, limit: Int = 76) -> String {
        let words = text.split(separator: " ")
        var kept: [Substring] = []
        var length = 0
        for word in words.reversed() {
            if length + word.count + 1 > limit, !kept.isEmpty { break }
            kept.append(word)
            length += word.count + 1
        }
        return kept.reversed().joined(separator: " ")
    }
}

/// Things people say when they want it to go away.
public enum Dismissal {
    private static let phrases = [
        "shut up", "be quiet", "stop talking", "stop listening", "go to sleep", "go away", "thats all", "that is all",
        "never mind", "nevermind", "goodbye", "bye bye", "leave me alone", "not now",
    ]

    /// Looks only at the end of what was said, since that is where it is meant.
    public static func matches(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "'", with: "").replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let recent = words.suffix(9)
        if recent.last == "bye" { return true }
        let sentence = recent.joined(separator: " ")
        return phrases.contains { sentence.contains($0) }
    }
}
