import Foundation

/// One other agent, as herdr reports it.
public struct AgentSnapshot: Equatable, Sendable {
    public enum Status: String, Sendable {
        case idle, working, blocked, done, unknown
    }

    public var paneID: String
    public var name: String?
    public var title: String?
    public var status: Status
    public var directory: String?
    /// Which agent it is, in herdr's word for it: "claude", "codex" and so on.
    public var kind: String?

    public init(paneID: String, name: String?, title: String?, status: Status, directory: String?, kind: String? = nil) {
        self.paneID = paneID
        self.name = name
        self.title = title
        self.status = status
        self.directory = directory
        self.kind = kind
    }

    /// What to call it out loud: its name if it has one, else what it is working on.
    public var label: String {
        if let name, !name.isEmpty { return name }
        if let title, !title.isEmpty { return title }
        return "an agent"
    }

    /// Agents the assistant started carry this prefix, which is how it tells its
    /// own workers from the user's other sessions.
    public var isOwn: Bool { name?.hasPrefix(FleetTracker.ownPrefix) ?? false }

    /// Reads herdr's `agent.list` result.
    public static func list(from response: Data) -> [AgentSnapshot]? {
        guard let object = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let agents = result["agents"] as? [[String: Any]] else { return nil }
        return agents.compactMap { agent in
            guard let pane = agent["pane_id"] as? String else { return nil }
            return AgentSnapshot(
                paneID: pane,
                name: agent["name"] as? String,
                title: agent["terminal_title_stripped"] as? String,
                status: Status(rawValue: agent["agent_status"] as? String ?? "") ?? .unknown,
                directory: agent["cwd"] as? String,
                kind: agent["agent"] as? String)
        }
    }
}

/// Something about another agent worth telling the orchestrator.
public struct FleetEvent: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case blocked
        case finished
    }

    public var kind: Kind
    public var agent: AgentSnapshot
    /// The orchestrator set this agent going itself, so it is waiting on the answer.
    public var asked = false

    public var text: String {
        switch kind {
        case .blocked: return "\(agent.label) is blocked and waiting for input."
        case .finished: return "\(agent.label) finished its turn."
        }
    }

    public var meta: [String: String] {
        var meta = ["status": kind.rawValue, "pane_id": agent.paneID, "own": agent.isOwn ? "yes" : "no", "asked": asked ? "yes" : "no"]
        if let name = agent.name { meta["agent"] = name }
        if let directory = agent.directory { meta["project"] = (directory as NSString).lastPathComponent }
        return meta
    }
}

/// What one look at the fleet produced.
public struct FleetUpdate: Equatable, Sendable {
    public var summary: FleetSummary
    public var events: [FleetEvent]
    /// The orchestrator session's own status, nil when herdr does not know it.
    public var own: AgentSnapshot.Status?
    /// The assistant's own workers that are busy right now.
    public var workers: [AgentSnapshot]
    /// Every other agent, one line each, for the list the notch opens to.
    public var roster = FleetRoster()
}

/// Turns successive snapshots of every agent into the counts the notch shows and
/// the few changes worth a model turn.
///
/// Every agent's blocks and finished turns are passed on, and the orchestrator
/// decides which of them the user needs to hear. Two things are left out because
/// they are never news: turns the user was watching, and turns too short to be a
/// job. Neither is left out for an agent the orchestrator prompted itself: it
/// asked, so it is told the moment there is an answer, however quick.
public struct FleetTracker: Sendable {
    public static let ownPrefix = "jv-"

    /// A turn shorter than this is someone chatting with an agent, not a job finishing.
    public static let minimumTurn: TimeInterval = 20

    private var known: [String: AgentSnapshot.Status] = [:]
    private var workingSince: [String: Date] = [:]
    /// Agents that started a turn while the orchestrator was in the middle of
    /// its own, which is when it prompts them.
    private var asked: Set<String> = []
    private var ownWorkedAt = Date.distantPast
    /// An agent takes a moment to show as working after it is prompted, and by
    /// then the orchestrator's own turn may just have ended.
    public static let askedWithin: TimeInterval = 4
    private var primed = false
    private let ownName: String

    /// - Parameter ownName: the orchestrator session's own agent name, which is
    ///   left out of everything.
    public init(ownName: String) {
        self.ownName = ownName
    }

    public mutating func update(_ agents: [AgentSnapshot], now: Date = Date()) -> FleetUpdate {
        let own = agents.first { $0.name == ownName }?.status
        let others = agents.filter { $0.name != ownName }
        var summary = FleetSummary()
        var events: [FleetEvent] = []
        if own == .working { ownWorkedAt = now }
        for agent in others {
            switch agent.status {
            case .working: summary.working += 1
            case .blocked: summary.needsYou += 1
            case .done: summary.finished += 1
            case .idle, .unknown: break
            }
            let before = known[agent.paneID]
            if agent.status == .working, workingSince[agent.paneID] == nil {
                workingSince[agent.paneID] = now
                if primed, now.timeIntervalSince(ownWorkedAt) <= Self.askedWithin { asked.insert(agent.paneID) }
            }
            let worked = workingSince[agent.paneID].map { now.timeIntervalSince($0) } ?? 0
            if agent.status != .working { workingSince[agent.paneID] = nil }
            // The first snapshot is the state of the world, not news.
            guard primed, before != agent.status else { continue }
            let wasAsked = asked.contains(agent.paneID)
            if agent.status != .working { asked.remove(agent.paneID) }
            if agent.status == .blocked {
                events.append(FleetEvent(kind: .blocked, agent: agent, asked: wasAsked))
            } else if before == .working {
                if agent.isOwn || wasAsked, agent.status == .done || agent.status == .idle {
                    events.append(FleetEvent(kind: .finished, agent: agent, asked: wasAsked))
                } else if agent.status == .done, worked >= Self.minimumTurn {
                    // herdr marks a finished turn "done" until someone looks at
                    // the pane. Straight to idle means the user was watching it.
                    events.append(FleetEvent(kind: .finished, agent: agent))
                }
            }
        }
        known = Dictionary(others.map { ($0.paneID, $0.status) }, uniquingKeysWith: { first, _ in first })
        workingSince = workingSince.filter { known[$0.key] != nil }
        asked = asked.filter { known[$0] != nil }
        primed = true
        let workers = others.filter { $0.isOwn && $0.status == .working }
        let roster = FleetRoster(agents: others, workingSince: workingSince)
        return FleetUpdate(summary: summary, events: events, own: own, workers: workers, roster: roster)
    }
}
