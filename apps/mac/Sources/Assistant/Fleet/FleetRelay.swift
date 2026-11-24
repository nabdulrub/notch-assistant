import AssistantCore
import Foundation

/// Passes what the other agents are doing on to the orchestrator session:
/// finished turns and blocks in batches, and a nudge to look in on its own
/// workers when the user has heard nothing for a while.
@MainActor
final class FleetRelay {
    var onSummary: ((FleetSummary?) -> Void)?
    /// Whether the orchestrator session itself is mid-turn.
    var onBusy: ((Bool) -> Void)?
    /// Whether this is a moment where a check-in would not be talking over anyone.
    var isQuiet: (() -> Bool)?
    var send: ((BridgeMessage) -> Void)?
    var onNote: ((String) -> Void)?
    /// Every other agent, each time they are looked at. Text mode draws them.
    var onRoster: ((FleetRoster) -> Void)?
    /// Blocks and finished turns, the moment they are seen.
    var onEvents: (([FleetEvent]) -> Void)?

    private let feed: HerdrFeed
    private let updateEvery: Double
    private var busy = false
    private var lastWorkerUpdate: Date?
    private var pending: [FleetEvent] = []
    private var timer: Timer?

    init(ownName: String, updateEvery: Double) {
        feed = HerdrFeed(ownName: ownName)
        self.updateEvery = updateEvery
    }

    func start() {
        feed.onUpdate = { [weak self] update in
            guard let self else { return }
            self.onSummary?(update.summary.isEmpty ? nil : update.summary)
            self.onRoster?(update.roster)
            if !update.events.isEmpty { self.onEvents?(update.events) }
            let busy = update.own == .working
            if busy != self.busy {
                self.busy = busy
                Log.write(busy ? "session working" : "session idle")
                self.onBusy?(busy)
            }
            self.checkIn(on: update.workers)
            self.report(update.events)
        }
        feed.start()
    }

    func lookNow() {
        feed.lookNow()
    }

    /// The user just heard something, so the next check-in can wait.
    func spoke() {
        if lastWorkerUpdate != nil { lastWorkerUpdate = Date() }
    }

    private func checkIn(on workers: [AgentSnapshot]) {
        guard updateEvery > 0, !workers.isEmpty else {
            lastWorkerUpdate = nil
            return
        }
        guard let last = lastWorkerUpdate else {
            lastWorkerUpdate = Date()
            return
        }
        guard Date().timeIntervalSince(last) >= updateEvery, !busy, isQuiet?() ?? true else { return }
        lastWorkerUpdate = Date()
        let names = workers.map(\.label).joined(separator: ", ")
        Log.write("check-in on \(names)")
        onNote?("Checking on \(workers.count == 1 ? names : "the workers")")
        send?(.event(kind: "checkin",
                     text: "Still working: \(names). The user has heard nothing for a while. Look at where they are and say one short line.",
                     meta: ["workers": String(workers.count)]))
    }

    private func report(_ events: [FleetEvent]) {
        guard !events.isEmpty else { return }
        for event in events {
            Log.write("fleet: \(event.text)")
            pending.removeAll { $0.agent.paneID == event.agent.paneID }
            pending.append(event)
        }
        guard timer == nil else { return }
        // Its own workers, and agents it asked something, are what the user is
        // waiting on; those go out quickly.
        let wait: TimeInterval = pending.contains { $0.agent.isOwn || $0.asked } ? 1.5 : 8
        timer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        timer = nil
        let events = pending
        pending.removeAll()
        guard !events.isEmpty else { return }
        let lines = events.map { event -> String in
            let project = event.agent.directory.map { ", in " + ($0 as NSString).lastPathComponent } ?? ""
            let whose = event.agent.isOwn ? "your worker" : event.asked ? "not yours, but you prompted it and this is its answer" : "not yours"
            return "- \(event.text) (pane \(event.agent.paneID), \(whose)\(project))"
        }
        onNote?("Checking in on the agents")
        send?(.event(kind: "agents", text: lines.joined(separator: "\n"), meta: ["count": String(events.count)]))
    }
}
