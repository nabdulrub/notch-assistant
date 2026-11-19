import AssistantCore
import Foundation

/// Starts the Claude Code session in herdr, in a tab of its own, the same way it
/// would be done by hand: make a tab, start the agent in it, and say yes when
/// Claude Code asks about the development channel.
enum SessionStarter {
    static var herdrPath: String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin/herdr", "/usr/local/bin/herdr", "\(home)/.local/bin/herdr", "\(home)/.cargo/bin/herdr"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Whether Claude Code is on this Mac. The usual places are looked in first;
    /// failing that, a login shell is asked, since that is where it will be run.
    static func claudeInstalled() async -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        if usual.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return true }
        return await Task.detached { run("/bin/zsh", ["-lc", "command -v claude"]).status == 0 }.value
    }

    /// - Returns: nil when the session was started, or a sentence saying what went wrong.
    static func start(herdr: String, name: String, directory: String, arguments: [String]) async -> String? {
        await Task.detached { () -> String? in
            let label = name.lowercased()
            let tab = run(herdr, ["tab", "create", "--label", label, "--cwd", directory])
            guard tab.status == 0, let pane = firstValue(of: "pane_id", in: tab.output) else {
                return "herdr would not open a tab. Is it running?"
            }
            // The agent start waits for Claude Code to be ready, and Claude Code
            // waits for an answer about the channel, so the two run side by side.
            let start = Process()
            start.executableURL = URL(fileURLWithPath: herdr)
            start.arguments = ["agent", "start", label, "--kind", "claude", "--pane", pane, "--timeout", "30000", "--"] + arguments
            let output = Pipe()
            start.standardOutput = output
            start.standardError = output
            do { try start.run() } catch { return "herdr could not be started." }
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(1))
                let screen = run(herdr, ["pane", "read", pane, "--source", "visible", "--lines", "30"]).output
                if screen.contains("local development") {
                    _ = run(herdr, ["pane", "send-keys", pane, "enter"])
                    break
                }
                if !start.isRunning { break }
            }
            start.waitUntilExit()
            let said = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if start.terminationStatus != 0 {
                Log.write("herdr agent start failed: \(said.prefix(300))")
                return "herdr opened a tab but Claude Code did not start in it. Have a look at the \(label) tab."
            }
            return nil
        }.value
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func firstValue(of key: String, in json: String) -> String? {
        guard let range = json.range(of: "\"\(key)\":\"") else { return nil }
        let rest = json[range.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
