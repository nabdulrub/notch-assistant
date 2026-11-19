import AVFoundation
import AppKit
import AssistantCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private let forceSetup: Bool
    private let openSettings: Bool
    private var setup: SetupWindowController?
    private var settingsWindow: SettingsWindowController?
    /// Set when a saved change needs the app itself to start again.
    private var restartWhenSettingsClose = false
    private var model: NotchModel?
    private var notch: NotchController?
    private var demoDriver: DemoDriver?
    private var conversation: LiveConversation?
    private var localModel: SophonServer?
    private var bridge: BridgeServer?
    private var statusItem: NSStatusItem?

    init(demo: Bool, setup: Bool = false, settings: Bool = false) {
        self.demo = demo
        forceSetup = setup
        openSettings = settings
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsStore.standard.load()
        let model = NotchModel(assistantName: settings.assistantName)
        self.model = model
        notch = NotchController(model: model)
        installStatusItem(settings: settings)

        if demo {
            let driver = DemoDriver(model: model)
            driver.start()
            demoDriver = driver
            return
        }

        SessionFiles.write(settings: settings)
        let bridge = BridgeServer()
        guard bridge.start() else {
            Log.write("could not open the bridge socket; is another copy running?")
            return
        }
        self.bridge = bridge

        // The first time, and whenever asked, setup comes before listening.
        if forceSetup || !settings.setupDone {
            showSetup()
        } else {
            startConversation(settings, setupIfNotReady: true)
            if openSettings { showSettings() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The model on this Mac holds a lot of memory; it goes when the app goes.
        localModel?.stop()
    }

    private var isConversing: Bool { conversation != nil }

    @objc private func sendToSleep() {
        conversation?.dismiss(how: "the menu")
    }

    @objc private func showSettings() {
        guard setup == nil else { return }
        if let settingsWindow { return settingsWindow.show() }
        let controller = SettingsWindowController(settings: SettingsStore.standard.load()) { [weak self] in
            guard let self else { return }
            self.settingsWindow = nil
            if self.isConversing {
                if self.restartWhenSettingsClose { self.relaunch() }
            } else if self.setup == nil {
                self.startConversation(SettingsStore.standard.load())
            }
        }
        controller.model.onSave = { [weak self] old, new in self?.apply(old: old, new: new) ?? "Saved." }
        controller.model.onOpenSetup = { [weak self] in
            // Setup takes the window's place. One at a time, since each of them
            // decides whether the app shows in the Dock.
            self?.settingsWindow?.close()
            self?.showSetup()
        }
        settingsWindow = controller
        controller.show()
    }

    /// Puts saved settings to work without making the user start anything again
    /// where that can be helped, and says in a sentence what became of them.
    private func apply(old: AssistantSettings, new: AssistantSettings) -> String {
        SessionFiles.write(settings: new)
        var said = ["Saved."]
        if Persona.instructions(for: old) != Persona.instructions(for: new) {
            let reached = bridge?.send(.event(kind: "instructions", text: Persona.update(for: new))) ?? false
            Log.write(reached ? "sent the session its new instructions" : "new instructions written; no session attached to send them to")
            said.append(reached ? "The session has its new instructions." : "No session is attached, so it reads them when one starts.")
        }
        if old.model != new.model {
            // A running session is left on its model. Switching it from outside
            // means typing /model into it, and that also rewrites the model
            // every new Claude Code session of the user's starts on.
            said.append("The session runs on \(new.model) the next time it starts.")
        }
        if old.needsRestart(toBecome: new), isConversing {
            restartWhenSettingsClose = true
            said.append("The rest takes hold when you close this window.")
        }
        return said.joined(separator: " ")
    }

    @objc private func showSetup() {
        guard setup == nil, settingsWindow == nil else { return }
        let controller = SetupWindowController(settings: SettingsStore.standard.load(), bridge: bridge) { [weak self] finished in
            guard let self else { return }
            self.setup = nil
            if self.isConversing {
                // Already running on the old choices; start again on the new ones.
                if finished { self.relaunch() }
            } else {
                // Closed halfway or finished, it starts with whatever was saved.
                self.startConversation(SettingsStore.standard.load())
            }
        }
        setup = controller
        controller.show()
    }

    private func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open -n \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// - Parameter setupIfNotReady: open setup when the chosen voice cannot
    ///   run yet. Not when setup has just been closed, or it would never close.
    private func startConversation(_ settings: AssistantSettings, setupIfNotReady: Bool = false) {
        guard let model, let bridge, !isConversing else { return }
        model.assistantName = settings.assistantName
        SessionFiles.write(settings: settings)

        let line: () -> VoiceLine
        if settings.voiceEngine == "sophon" {
            let server = SophonServer()
            guard server.start(name: settings.assistantName) else {
                Log.write("the voice on this Mac is not installed yet")
                if setupIfNotReady { showSetup() }
                return
            }
            localModel = server
            Log.write("voice: on this Mac")
            line = { SophonSession(port: SophonServer.port) }
        } else {
            // The live voice runs on the user's own OpenAI key. There is no
            // shared one to fall back on.
            guard let key = Secrets.openAIKey else {
                Log.write("the live voice needs your own OpenAI key")
                if setupIfNotReady { showSetup() }
                return
            }
            Log.write("voice: live")
            let voice = settings.liveVoice
            let instructions = LivePersona.instructions(name: settings.assistantName, personality: settings.personality)
            line = { LiveSession(key: key, voice: voice, instructions: instructions) }
        }
        // One engine for the microphone and the voice, so the echo canceller
        // knows what is being played.
        let conversation = LiveConversation(settings: settings, model: model, bridge: bridge, engine: AVAudioEngine(), line: line)
        conversation.start()
        self.conversation = conversation
    }

    private func installStatusItem(settings: AssistantSettings) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eyes", accessibilityDescription: settings.assistantName)
        let menu = NSMenu()
        let header = NSMenuItem(
            title: demo ? "Demo mode" : "Say \"\(settings.assistantName)\" or press \(settings.talkKey.display)",
            action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !demo {
            let sleepItem = NSMenuItem(title: "Send \(settings.assistantName) to Sleep", action: #selector(sendToSleep), keyEquivalent: "")
            sleepItem.target = self
            menu.addItem(sleepItem)
            let settingsItem = NSMenuItem(title: "Settings\u{2026}", action: #selector(showSettings), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)
            let setupItem = NSMenuItem(title: "Run Setup Again\u{2026}", action: #selector(showSetup), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit \(settings.assistantName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }
}

/// The files a session needs to find the helper: written on every launch so they
/// always point at the copy of the app that is actually running.
enum SessionFiles {
    static var mcpConfig: URL { SettingsStore.standard.directory.appendingPathComponent("mcp.json") }
    static var persona: URL { SettingsStore.standard.directory.appendingPathComponent("persona.md") }
    static var sessionSettings: URL { SettingsStore.standard.directory.appendingPathComponent("session-settings.json") }

    static var helperPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("assistant-channel").path
    }

    static func write(settings: AssistantSettings) {
        let data = SessionCommand.mcpConfig(helperPath: helperPath, assistantName: settings.assistantName,
                                            socketPath: UnixSocket.standardPath, personaPath: persona.path)
        try? FileManager.default.createDirectory(at: SettingsStore.standard.directory, withIntermediateDirectories: true)
        try? data.write(to: mcpConfig, options: .atomic)
        try? Data(Persona.instructions(for: settings).utf8).write(to: persona, options: .atomic)
        try? SessionCommand.sessionSettings(helperPath: helperPath).write(to: sessionSettings, options: .atomic)
    }

    static func session(settings: AssistantSettings) -> SessionCommand {
        SessionCommand(assistantName: settings.assistantName, model: settings.model, mcpConfigPath: mcpConfig.path, personaPath: persona.path,
                       settingsPath: sessionSettings.path)
    }

    /// `claude` and everything after it, one argument each.
    static func arguments(settings: AssistantSettings) -> [String] {
        session(settings: settings).arguments
    }

    static func command(settings: AssistantSettings) -> String {
        let directory = (settings.workingDirectory as NSString).expandingTildeInPath
        return "cd \(SessionCommand.quote(directory)) && \(session(settings: settings).shellLine)"
    }
}
