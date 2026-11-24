import AppKit
import AssistantCore

/// The delegate has to outlive the call that installs it.
nonisolated(unsafe) var delegateHolder: AnyObject?

let arguments = CommandLine.arguments

func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

/// `--appcast` prints the update feed for one release. The release script
/// passes what Sparkle's `sign_update` printed for the disk image.
if arguments.contains("--appcast") {
    guard let version = value(after: "--version"), let build = value(after: "--build"), let url = value(after: "--url"),
          let signed = value(after: "--signed").flatMap(Appcast.signature(fromSignUpdate:)) else {
        print("usage: Assistant --appcast --version 0.2 --build 41 --url <dmg url> --signed '<what sign_update printed>' [--name <app name>]")
        exit(2)
    }
    let release = AppRelease(version: version, build: build, url: url, signature: signed.signature, length: signed.length)
    print(Appcast.xml(appName: value(after: "--name") ?? "Notch Assistant", release: release), terminator: "")
    exit(0)
}

/// `--snapshot <dir>` writes one PNG per demo state and exits.
if arguments.contains("--snapshot") {
    guard let path = value(after: "--snapshot") else {
        print("usage: Assistant --snapshot <directory>")
        exit(2)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do {
            let name = SettingsStore.standard.load().assistantName
            let metrics = NotchMetrics(width: 190, height: 34, hasHardwareNotch: true)
            for file in try Snapshot.run(directory: URL(fileURLWithPath: path, isDirectory: true), name: name, metrics: metrics) {
                print(file.path)
            }
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }
}

/// `--snapshot-settings <dir>` does the same for the settings window.
if arguments.contains("--snapshot-settings") {
    guard let path = value(after: "--snapshot-settings") else {
        print("usage: Assistant --snapshot-settings <directory>")
        exit(2)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do {
            for file in try Snapshot.settings(directory: URL(fileURLWithPath: path, isDirectory: true)) { print(file.lastPathComponent) }
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }
}

/// `--snapshot-setup <dir>` does the same for the setup screens.
if arguments.contains("--snapshot-setup") {
    guard let path = value(after: "--snapshot-setup") else {
        print("usage: Assistant --snapshot-setup <directory>")
        exit(2)
    }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do {
            for file in try Snapshot.setup(directory: URL(fileURLWithPath: path, isDirectory: true)) { print(file.lastPathComponent) }
            exit(0)
        } catch {
            print("snapshot failed: \(error)")
            exit(1)
        }
    }
}

/// `--icon <file.png>` draws the app icon. The bundle script calls it.
if arguments.contains("--icon") {
    guard let path = value(after: "--icon") else { exit(2) }
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        do {
            try Snapshot.icon(to: URL(fileURLWithPath: path))
            exit(0)
        } catch {
            print("icon failed: \(error)")
            exit(1)
        }
    }
}

/// `--session-command` prints the line that starts the orchestrator session.
if arguments.contains("--session-command") {
    let settings = SettingsStore.standard.load()
    SessionFiles.write(settings: settings)
    print(SessionFiles.command(settings: settings))
    exit(0)
}

/// `--say "text"` hands text to the running app as if it had been spoken, so the
/// whole loop can be exercised without a microphone.
if arguments.contains("--say") {
    guard let text = value(after: "--say"), let descriptor = UnixSocket.connect(path: UnixSocket.standardPath) else {
        print("the app is not running, or there was nothing to say")
        exit(1)
    }
    let connection = LineConnection(descriptor: descriptor)
    connection.send(BridgeMessage.utterance(text, source: "typed").encoded())
    connection.close()
    exit(0)
}

/// `--nudge` tells the running app to look at the agents now. The herdr plugin
/// does the same over the socket on every status change.
if arguments.contains("--nudge") {
    guard let descriptor = UnixSocket.connect(path: UnixSocket.standardPath) else { exit(1) }
    let connection = LineConnection(descriptor: descriptor)
    connection.send(BridgeMessage.nudge.encoded())
    connection.close()
    exit(0)
}

/// `--fleet` prints what herdr reports about the other agents, once.
if arguments.contains("--fleet") {
    guard let agents = HerdrFeed.snapshot() else {
        print("herdr is not running")
        exit(1)
    }
    var tracker = FleetTracker(ownName: SettingsStore.standard.load().assistantName.lowercased())
    let summary = tracker.update(agents).summary
    print("\(agents.count) agents: \(summary.isEmpty ? "all idle" : summary.line)")
    for agent in agents { print("  \(agent.status.rawValue)\t\(agent.isOwn ? "own" : "   ")\t\(agent.name ?? "-")") }
    exit(0)
}

/// `--store-openai-key` reads the key from standard input, so it never appears
/// in a command line or a shell history.
if arguments.contains("--store-openai-key") {
    let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    do {
        try Secrets.storeOpenAIKey(key)
        print("stored")
        exit(0)
    } catch {
        print("nothing stored: the input was empty")
        exit(1)
    }
}

/// `--check-keys` asks OpenAI whether the stored key still works. With `--bad`
/// it sends a made-up key instead, to see a refusal.
if arguments.contains("--check-keys") {
    let bad = arguments.contains("--bad")
    let done = DispatchSemaphore(value: 0)
    Task.detached {
        if let key = bad ? "sk-not-a-real-key" : Secrets.openAIKey {
            print("OpenAI: \(await KeyCheck.openAI(key) ?? "works")")
        } else {
            print("OpenAI: no key stored")
        }
        done.signal()
    }
    done.wait()
    exit(0)
}

// Opened twice by accident, the second copy leaves at once.
guard SingleInstance.claim() else {
    Log.write("another copy is already running; this one is leaving")
    exit(0)
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    // `--setup` opens the first-run setup again, whether or not it was finished.
    // `--settings` opens the settings window as it starts.
    // `--demo --text` plays text mode's states instead of the voice ones.
    let delegate = AppDelegate(demo: arguments.contains("--demo"), demoText: arguments.contains("--text"), setup: arguments.contains("--setup"),
                               settings: arguments.contains("--settings"))
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    delegateHolder = delegate
    application.run()
}
