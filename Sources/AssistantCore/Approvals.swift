import Foundation

/// Reads a spoken answer to "should I go ahead?".
public enum Confirmation: Equatable, Sendable {
    case yes
    case no
    case unclear

    static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "confirmed",
        "allow", "allowed", "approve", "approved", "absolutely", "definitely",
    ]
    static let yesPhrases = ["go ahead", "do it", "go for it", "please do", "sounds good", "thats fine", "its fine"]
    static let noWords: Set<String> = [
        "no", "nope", "nah", "deny", "denied", "dont", "stop", "cancel", "reject", "wait", "never", "not",
    ]
    static let noPhrases = ["hold on", "do not"]

    /// A no anywhere wins over a yes ("yes, no wait"). A long sentence is never a
    /// yes: an approval is a short answer, and a stray "okay" in the middle of
    /// someone's conversation must not approve a command.
    public static func parse(_ transcript: String) -> Confirmation {
        let words = WakeMatcher.words(transcript).map(\.key)
        guard !words.isEmpty else { return .unclear }
        let sentence = words.joined(separator: " ")
        if words.contains(where: noWords.contains) || noPhrases.contains(where: sentence.contains) {
            return .no
        }
        guard words.count <= 6 else { return .unclear }
        if words.contains(where: yesWords.contains) || yesPhrases.contains(where: sentence.contains) {
            return .yes
        }
        return .unclear
    }
}

/// Turns a raw permission prompt into something a person would say.
public enum ApprovalPhrase {
    /// What the assistant wants, as the end of the sentence "Hey, so I wanna …".
    public static func intent(tool: String, description: String, preview: String) -> String {
        let said = description.trimmingCharacters(in: .whitespacesAndNewlines)
        switch tool {
        case "Bash":
            if said.isEmpty || said.lowercased() == "run shell command" {
                return "run a command in the terminal"
            }
            return "run a command: " + lowercasedFirst(said)
        case "Write":
            return file(preview).map { "write the file \($0)" } ?? "write a file"
        case "Edit", "MultiEdit", "NotebookEdit":
            return file(preview).map { "edit \($0)" } ?? "edit a file"
        case "WebFetch":
            return "open a web page"
        case "WebSearch":
            return "search the web"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.dropFirst(5).components(separatedBy: "__")
                if parts.count >= 2 {
                    let action = parts[1...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
                    return "use \(action) from \(parts[0].replacingOccurrences(of: "_", with: " "))"
                }
            }
            if !said.isEmpty { return lowercasedFirst(said) }
            return "use \(tool)"
        }
    }

    public static func summary(tool: String, description: String, preview: String) -> String {
        "Okay to " + trimmedEnd(intent(tool: tool, description: description, preview: preview)) + "?"
    }

    public static func spoken(tool: String, description: String, preview: String) -> String {
        "Hey, so I wanna " + trimmedEnd(intent(tool: tool, description: description, preview: preview))
            + ". Cool if I go ahead?"
    }

    /// The file a Write or Edit is aimed at, by its name only. Nobody wants a full
    /// path read out to them.
    static func file(_ preview: String) -> String? {
        guard let range = preview.range(of: #""file_path"\s*:\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let match = String(preview[range])
        guard let open = match.range(of: #":\s*""#, options: .regularExpression) else { return nil }
        let path = match[open.upperBound...].dropLast()
        let name = path.split(separator: "/").last.map(String.init) ?? String(path)
        return name.isEmpty ? nil : name
    }

    static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        // Leave an acronym or a name alone ("PR", "GitHub").
        let second = text.dropFirst().first
        if let second, second.isUppercase { return text }
        return first.lowercased() + text.dropFirst()
    }

    static func trimmedEnd(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
    }
}
