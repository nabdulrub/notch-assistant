import AssistantCore
import Foundation

/// The app's end of the socket. A session's helper connects and says hello; a
/// debug client can connect and push text as if the user had said it.
final class BridgeServer: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: LineConnection] = [:]

    /// Called on the main thread.
    var onMessage: (@MainActor (BridgeMessage) -> Void)?
    var onSessionCount: (@MainActor (Int) -> Void)?
    /// A session asked to see the screen. The answer goes back to that session
    /// only: another one would take it for the answer to a call of its own.
    var onLook: (@MainActor (_ requestId: String, _ answer: @escaping @Sendable (BridgeMessage) -> Void) -> Void)?

    init(path: String = UnixSocket.standardPath) {
        self.path = path
    }

    var sessionCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sessions.count
    }

    func start() -> Bool {
        guard let listener = UnixSocket.listen(path: path) else { return false }
        let thread = Thread { [weak self] in
            while let descriptor = UnixSocket.accept(listener) {
                self?.serve(LineConnection(descriptor: descriptor))
            }
        }
        thread.start()
        return true
    }

    private func serve(_ connection: LineConnection) {
        let thread = Thread { [weak self] in
            connection.readLines { line in
                guard let self, let message = BridgeMessage.decode(line) else { return }
                if message.type == .hello {
                    self.setSession(connection, attached: true)
                    return
                }
                if message.type == .look, let requestId = message.requestId {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            self.onLook?(requestId) { answer in _ = connection.send(answer.encoded()) }
                        }
                    }
                    return
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self.onMessage?(message) }
                }
            }
            self?.setSession(connection, attached: false)
            connection.close()
        }
        thread.start()
    }

    private func setSession(_ connection: LineConnection, attached: Bool) {
        lock.lock()
        let key = ObjectIdentifier(connection)
        let known = sessions[key] != nil
        if attached { sessions[key] = connection } else { sessions[key] = nil }
        let count = sessions.count
        lock.unlock()
        guard attached != known else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.onSessionCount?(count) }
        }
    }

    /// Sends to every attached session. False when there is none to hear it.
    @discardableResult
    func send(_ message: BridgeMessage) -> Bool {
        lock.lock()
        let targets = Array(sessions.values)
        lock.unlock()
        let line = message.encoded()
        return targets.reduce(false) { $1.send(line) || $0 }
    }
}
