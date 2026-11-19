import Foundation

/// Where the assistant is in a turn. The notch draws from this and nothing else.
public enum Phase: String, CaseIterable, Codable, Sendable {
    case asleep
    case listening
    case thinking
    case speaking
    case followUp

    public var isAwake: Bool { self != .asleep }
}

/// A permission prompt relayed from the session, waiting on the user.
public struct ApprovalRequest: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var tool: String
    public var summary: String
    public var preview: String
    /// Risky requests take a click. A spoken yes is not enough.
    public var clickOnly: Bool

    public init(id: String, tool: String, summary: String, preview: String, clickOnly: Bool) {
        self.id = id
        self.tool = tool
        self.summary = summary
        self.preview = preview
        self.clickOnly = clickOnly
    }
}

/// Counts of the other agents, drawn in the notch without asking the model.
public struct FleetSummary: Equatable, Codable, Sendable {
    public var working: Int
    public var needsYou: Int
    public var finished: Int

    public init(working: Int = 0, needsYou: Int = 0, finished: Int = 0) {
        self.working = working
        self.needsYou = needsYou
        self.finished = finished
    }

    public var isEmpty: Bool { working == 0 && needsYou == 0 && finished == 0 }

    public var line: String {
        var parts: [String] = []
        if needsYou > 0 { parts.append(needsYou == 1 ? "1 needs you" : "\(needsYou) need you") }
        if working > 0 { parts.append("\(working) working") }
        if finished > 0 { parts.append("\(finished) finished") }
        return parts.joined(separator: ", ")
    }
}
