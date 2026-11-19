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
                    Thread.sleep(forTimeInterval: interval)
                }
                connection.close()
                Thread.sleep(forTimeInterval: 3)
            }
        }
        thread.start()
    }
}
