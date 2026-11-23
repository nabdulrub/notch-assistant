import AssistantCore
import Foundation

/// Watches every agent in the running herdr session by asking for the list every
/// couple of seconds. Asking is cheap, and it needs none of the bookkeeping that
/// per-pane subscriptions do when panes come and go.
///
/// If herdr is not running there is simply nothing to report, which is the plain
/// Claude Code case.
final class HerdrFeed: @unchecked Sendable {
    static var socketPath: String {
        if let override = ProcessInfo.processInfo.environment["HERDR_SOCKET_PATH"], !override.isEmpty { return override }
        return ("~/.config/herdr/herdr.sock" as NSString).expandingTildeInPath
    }

    @MainActor var onUpdate: ((FleetUpdate) -> Void)?

    private let interval: TimeInterval
    private let ownName: String
    private let wake = DispatchSemaphore(value: 0)

    init(ownName: String, interval: TimeInterval = 1) {
        self.ownName = ownName
        self.interval = interval
    }

    /// One snapshot, for the command line check.
    static func snapshot() -> [AgentSnapshot]? {
        guard let descriptor = UnixSocket.connect(path: socketPath) else { return nil }
        let connection = LineConnection(descriptor: descriptor)
        defer { connection.close() }
        connection.send(Data(#"{"id":"list","method":"agent.list","params":{}}"#.utf8))
        return connection.nextLine().flatMap(AgentSnapshot.list(from:))
    }

    /// Types a message into one agent's pane and submits it, the way herdr's own
    /// `agent prompt` does. Blocks until herdr answers, so not on the main thread.
    /// - Returns: nil when it went in, else herdr's word for why it did not.
    static func prompt(pane: String, text: String) -> PromptProblem? {
        guard let descriptor = UnixSocket.connect(path: socketPath) else { return .notRunning }
        let connection = LineConnection(descriptor: descriptor)
        defer { connection.close() }
        let request: [String: Any] = ["id": "prompt", "method": "agent.prompt", "params": ["target": pane, "text": text]]
        guard let line = try? JSONSerialization.data(withJSONObject: request), connection.send(line),
              let answer = connection.nextLine(),
              let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { return .notRunning }
        guard let error = object["error"] as? [String: Any] else { return nil }
        switch error["code"] as? String {
        case "agent_blocked": return .blocked
        case "agent_not_found": return .gone
        default: return .other(error["message"] as? String ?? "herdr refused it")
        }
    }

    enum PromptProblem: Equatable {
        case notRunning
        /// It is stopped on a question of its own, which a message cannot answer.
        case blocked
        case gone
        case other(String)
    }

    /// Asks again at once. The herdr plugin calls this on every status change, so a
    /// turn shorter than the wait between two looks is still seen.
    func lookNow() {
        wake.signal()
    }

    func start() {
        let thread = Thread { [self] in
            var tracker = FleetTracker(ownName: ownName)
            while true {
                guard let descriptor = UnixSocket.connect(path: HerdrFeed.socketPath) else {
                    Thread.sleep(forTimeInterval: 10)
                    continue
                }
                let connection = LineConnection(descriptor: descriptor)
                while connection.send(Data(#"{"id":"list","method":"agent.list","params":{}}"#.utf8)),
                      let line = connection.nextLine() {
                    if let agents = AgentSnapshot.list(from: line) {
                        let update = tracker.update(agents)
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated { self?.onUpdate?(update) }
                        }
                    }
                    _ = wake.wait(timeout: .now() + interval)
                }
                connection.close()
                Thread.sleep(forTimeInterval: 3)
            }
        }
        thread.start()
    }
}
