import Foundation

/// Holds the session to the worker models the user set.
///
/// The instructions say which models workers run on, and a session with a long
/// history of starting them another way, or with other rules in its own
/// instructions, does not always follow. So the start itself is checked: a
/// worker on any other model is refused, with the reason, and the session
/// starts it again.
public enum WorkerModelCheck {
    /// Why this tool call may not go ahead, or nil when it may.
    ///
    /// Only checked when both models are set. With either left to the user's
    /// own instructions, any model may be the right one.
    public static func refusal(tool: String, input: [String: Any], delegation: Delegation) -> String? {
        let work = delegation.workerModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let light = delegation.lightWorkerModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !work.isEmpty, !light.isEmpty else { return nil }
        let allowed = [work, light]

        let asked: [String?]
        switch tool {
        case "Bash":
            guard let command = input["command"] as? String else { return nil }
            asked = modelsOfWorkersStarted(by: command)
        case "Agent", "Task":
            guard let model = input["model"] as? String else { return nil }
            asked = [model]
        default:
            return nil
        }
        guard let wrong = asked.first(where: { model in
            guard let model = model?.lowercased() else { return true }
            return !allowed.contains { model == $0 || model.contains($0) }
        }) else { return nil }

        let choice = work == light ? "the \(work) model" : "\(work) for real work, or \(light) for a small mechanical job"
        let found = wrong.map { "This one was started on \($0)." } ?? "This one was started with no model named."
        return "Workers run on \(choice). The user set that in Settings, and it wins over every other rule about worker models, "
            + "including the user's own CLAUDE.md and how you started workers before. \(found) Start it again with --model \(work)"
            + (work == light ? "." : ", or --model \(light) if it is a small job.")
    }

    /// The model each `herdr agent start` in a shell command names, nil where it names none.
    static func modelsOfWorkersStarted(by command: String) -> [String?] {
        guard let start = try? NSRegularExpression(pattern: #"\bagent\s+start\b"#),
              let model = try? NSRegularExpression(pattern: #"--model[\s=]+["']?([A-Za-z0-9._\[\]-]+)"#) else { return [] }
        let text = command as NSString
        let starts = start.matches(in: command, range: NSRange(location: 0, length: text.length))
        return starts.enumerated().map { index, match in
            // One start runs to the end of its own command, or to the next start.
            var end = index + 1 < starts.count ? starts[index + 1].range.location : text.length
            let rest = NSRange(location: match.range.upperBound, length: end - match.range.upperBound)
            let stop = text.rangeOfCharacter(from: CharacterSet(charactersIn: ";&|\n"), options: [], range: rest)
            if stop.location != NSNotFound { end = stop.location }
            let own = NSRange(location: match.range.upperBound, length: end - match.range.upperBound)
            guard let found = model.firstMatch(in: command, range: own) else { return nil }
            return text.substring(with: found.range(at: 1))
        }
    }
}
