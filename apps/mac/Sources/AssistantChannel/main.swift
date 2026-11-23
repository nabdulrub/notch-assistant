import AssistantCore
import Darwin
import Foundation

// The helper Claude Code spawns. It speaks MCP on stdin and stdout, and relays to
// the app over a local socket. It holds no state worth keeping: if the app
// restarts it reconnects, and if the session ends it exits.

signal(SIGPIPE, SIG_IGN)

// Asked by the session before it runs a command or starts a subagent: is a
// worker being started on a model the user set? Exit 2 refuses the call and
// gives the session the reason. Anything this cannot read goes ahead.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "hook" {
    let event = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any]
    if CommandLine.arguments[2] == "pre-tool-use", let tool = event?["tool_name"] as? String,
       let input = event?["tool_input"] as? [String: Any],
       let reason = WorkerModelCheck.refusal(tool: tool, input: input, delegation: SettingsStore.standard.load().delegation) {
        FileHandle.standardError.write(Data((reason + "\n").utf8))
        exit(2)
    }
    exit(0)
}

func argument(_ flag: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

let assistantName = AssistantSettings.cleaned(name: argument("--name") ?? "Jarvis")
let socketPath = argument("--socket") ?? UnixSocket.standardPath
// The app writes the instructions the user's settings add up to; without the
// file, the defaults.
let written = argument("--persona").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
let server = ChannelServer(assistantName: assistantName, instructions: written.flatMap { $0.isEmpty ? nil : $0 })

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

    func run(onMessage: @escaping @Sendable (BridgeMessage) -> Void, onDrop: @escaping @Sendable () -> Void) {
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
                onDrop()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        thread.stackSize = 1 << 20
        thread.start()
    }
}

/// Looks the app has been asked for and has not answered. A tool call must
/// always get an answer, so these are failed if the app goes away first.
final class Looks: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Set<String> = []

    func asked(_ requestId: String) {
        lock.lock()
        waiting.insert(requestId)
        lock.unlock()
    }

    func answered(_ requestId: String) {
        lock.lock()
        waiting.remove(requestId)
        lock.unlock()
    }

    func takeAll() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let all = Array(waiting)
        waiting.removeAll()
        return all
    }
}

let output = Output()
let app = AppLink(path: socketPath)
let looks = Looks()

func failLook(_ requestId: String) {
    looks.answered(requestId)
    let gone = BridgeMessage.noScreen(requestId: requestId, problem: "The \(assistantName) app went away before it could answer.")
    if let line = server.notification(for: gone) { output.write(line) }
}

app.run(onMessage: { message in
    if message.type == .screen, let requestId = message.requestId { looks.answered(requestId) }
    if let line = server.notification(for: message) {
        output.write(line)
    }
}, onDrop: {
    looks.takeAll().forEach(failLook)
})

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty else { continue }
    // Read each time: the mode can change under a session that keeps running.
    let typed = SettingsStore.standard.load().mode == .text
    let result = server.handle(line: Data(line.utf8), appConnected: app.isConnected, typed: typed)
    for message in result.toApp {
        guard message.type == .look, let requestId = message.requestId else {
            app.send(message)
            continue
        }
        looks.asked(requestId)
        if !app.send(message) { failLook(requestId) }
    }
    for reply in result.replies { output.write(reply) }
}
exit(0)
