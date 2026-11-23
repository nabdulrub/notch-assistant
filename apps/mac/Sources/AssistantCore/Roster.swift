import Foundation

/// How many sessions of one kind of agent are open, and how many are at work.
/// The notch shows the second number: an idle session is not news.
public struct KindCount: Equatable, Sendable {
    public var kind: String
    public var sessions: Int
    public var working: Int

    public init(kind: String, sessions: Int, working: Int) {
        self.kind = kind
        self.sessions = sessions
        self.working = working
    }
}

/// One agent, as a line of the list the notch opens to.
public struct AgentRow: Equatable, Identifiable, Sendable {
    public var paneID: String
    public var kind: String
    public var label: String
    public var project: String?
    public var status: AgentSnapshot.Status
    /// When its current turn started, while it is working.
    public var workingSince: Date?

    public var id: String { paneID }

    public init(paneID: String, kind: String, label: String, project: String?, status: AgentSnapshot.Status, workingSince: Date? = nil) {
        self.paneID = paneID
        self.kind = kind
        self.label = label
        self.project = project
        self.status = status
        self.workingSince = workingSince
    }

    /// Idle agents are folded away until asked for; these are not.
    public var isActive: Bool { status == .blocked || status == .working || status == .done }
}

/// Every other agent, counted by kind and listed in the order they matter:
/// whoever is waiting on the user first, then the ones at work, then the ones
/// that finished, and the idle ones last.
public struct FleetRoster: Equatable, Sendable {
    /// What an agent herdr has no kind for is counted under.
    public static let unknownKind = "agent"

    public var kinds: [KindCount]
    public var rows: [AgentRow]

    public init(kinds: [KindCount] = [], rows: [AgentRow] = []) {
        self.kinds = kinds
        self.rows = rows
    }

    public init(agents: [AgentSnapshot], workingSince: [String: Date] = [:]) {
        var counts: [String: KindCount] = [:]
        var rows: [AgentRow] = []
        for agent in agents {
            let kind = agent.kind.flatMap { $0.isEmpty ? nil : $0.lowercased() } ?? Self.unknownKind
            var count = counts[kind] ?? KindCount(kind: kind, sessions: 0, working: 0)
            count.sessions += 1
            if agent.status == .working { count.working += 1 }
            counts[kind] = count
            let project = agent.directory.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            rows.append(AgentRow(paneID: agent.paneID, kind: kind, label: Self.label(for: agent, project: project), project: project,
                                 status: agent.status, workingSince: agent.status == .working ? workingSince[agent.paneID] : nil))
        }
        kinds = counts.values.sorted { ($0.sessions, $1.kind) > ($1.sessions, $0.kind) }
        self.rows = rows.enumerated().sorted { first, second in
            let a = Self.rank(first.element), b = Self.rank(second.element)
            if a != b { return a < b }
            // The longest-running job first; otherwise the order herdr gave.
            if let since = first.element.workingSince, let other = second.element.workingSince, since != other { return since < other }
            return first.offset < second.offset
        }.map(\.element)
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var needsYou: Int { rows.filter { $0.status == .blocked }.count }
    public var idle: Int { rows.filter { !$0.isActive }.count }
    public var active: [AgentRow] { rows.filter(\.isActive) }

    /// The idle agents, in a line that stands in for them until they are asked for.
    public var idleLine: String {
        let count = idle
        if active.isEmpty { return count == 1 ? "1 idle agent" : "\(count) idle agents" }
        return count == 1 ? "1 more is idle" : "\(count) more are idle"
    }

    /// A name if it was given one, else what its terminal says it is doing,
    /// else the folder it is in.
    private static func label(for agent: AgentSnapshot, project: String?) -> String {
        if let name = agent.name, !name.isEmpty { return name }
        if let title = agent.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return project ?? "agent"
    }

    private static func rank(_ row: AgentRow) -> Int {
        switch row.status {
        case .blocked: return 0
        case .working: return 1
        case .done: return 2
        case .idle, .unknown: return 3
        }
    }
}

/// How long something has been going, in as few characters as the list has room for.
public enum Elapsed {
    /// Empty under a minute: "Working" says enough until then.
    public static func short(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0)) / 60
        if minutes < 1 { return "" }
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }
}

/// One line of the typed conversation in the notch.
public struct ChatMessage: Equatable, Identifiable, Sendable {
    public enum Role: Sendable {
        /// Typed by the user.
        case you
        /// What the session, or an agent's own status, had to say.
        case assistant
    }

    public var id: Int
    public var role: Role
    public var text: String
    /// The agent it was sent to, when it did not go to the session.
    public var to: AgentRow?

    public init(id: Int, role: Role, text: String, to: AgentRow? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.to = to
    }
}

/// The typed conversation. It keeps the last stretch only: the notch is not a
/// place to scroll back through a day.
public struct ChatLog: Equatable, Sendable {
    public static let most = 60

    public private(set) var messages: [ChatMessage] = []
    private var next = 0

    public init() {}

    public mutating func append(_ role: ChatMessage.Role, _ text: String, to: AgentRow? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        messages.append(ChatMessage(id: next, role: role, text: trimmed, to: to))
        next += 1
        if messages.count > Self.most { messages.removeFirst(messages.count - Self.most) }
    }
}

/// Something that just happened, shown under the notch for a moment while it is closed.
public struct NotchUpdate: Equatable, Sendable {
    /// The kind of agent it is about, for its icon. Nil when it is the session's own words.
    public var kind: String?
    public var title: String
    public var detail: String?

    public init(kind: String? = nil, title: String, detail: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    /// An agent stopped for the user, or finished a job.
    public init(_ event: FleetEvent) {
        let row = FleetRoster(agents: [event.agent]).rows[0]
        kind = row.kind
        title = row.label + (event.kind == .blocked ? " needs you" : " finished")
        detail = row.project == row.label ? nil : row.project
    }

    /// Several things at once: whoever is waiting on the user comes first, and
    /// the rest are counted.
    public init?(events: [FleetEvent]) {
        guard let first = events.first(where: { $0.kind == .blocked }) ?? events.first else { return nil }
        self.init(first)
        let others = events.count - 1
        if others > 0 { detail = others == 1 ? "and 1 more" : "and \(others) more" }
    }
}
