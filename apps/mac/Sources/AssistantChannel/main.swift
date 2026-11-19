import AssistantCore
import Darwin
import Foundation

// The helper Claude Code spawns. It speaks MCP on stdin and stdout, and relays to
// the app over a local socket. It holds no state worth keeping: if the app
// restarts it reconnects, and if the session ends it exits.

signal(SIGPIPE, SIG_IGN)

func argument(_ flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

let assistantName = AssistantSettings.cleaned(name: argument("--name") ?? "Jarvis")
let socketPath = argument("--socket") ?? UnixSocket.standardPath
let server = ChannelServer(assistantName: assistantName)

/// Stdout is shared by the reader loop and the socket thread; one line at a time.
final class Output: @unchecked Sendable {
    private let lock = NSLock()

    func write(_ line: Data) {
        lock.lock()
        defer { lock.unlock() }
        var payload = line
        payload.append(0x0A)
        FileHandle.standardOutput.write(payload)
    }
}

/// The link to the app. Keeps trying while the app is not running, so the order
/// the two are started in does not matter.
final class AppLink: @unchecked Sendable {
    private let path: String
    private let lock = NSLock()
    private var connection: LineConnection?

    init(path: String) {
        self.path = path
    }

    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connection != nil
    }

    @discardableResult
    func send(_ message: BridgeMessage) -> Bool {
        lock.lock()
        let current = connection
        lock.unlock()
        return current?.send(message.encoded()) ?? false
    }

    func run(onMessage: @escaping @Sendable (BridgeMessage) -> Void) {
        let thread = Thread { [self] in
            while true {
                guard let descriptor = UnixSocket.connect(path: path) else {
                    Thread.sleep(forTimeInterval: 1)
                    continue
                }
                let link = LineConnection(descriptor: descriptor)
                link.send(BridgeMessage.hello.encoded())
                lock.lock()
                connection = link
                lock.unlock()
                link.readLines { line in
                    if let message = BridgeMessage.decode(line) { onMessage(message) }
                }
                lock.lock()
                connection = nil
                lock.unlock()
                link.close()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

let output = Output()
let app = AppLink(path: socketPath)

app.run { message in
    if let line = server.notification(for: message) {
        output.write(line)
    }
}

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    let result = server.handle(line: Data(line.utf8), appConnected: app.isConnected)
    for message in result.toApp { app.send(message) }
    for reply in result.replies { output.write(reply) }
}
exit(0)
