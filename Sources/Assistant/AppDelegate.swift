import AVFoundation
import AppKit
import AssistantCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let demo: Bool
    private let forceSetup: Bool
    private var setup: SetupWindowController?
    private var model: NotchModel?
    private var notch: NotchController?
    private var demoDriver: DemoDriver?
    private var conversation: Conversation?
    private var liveConversation: LiveConversation?
    private var bridge: BridgeServer?
    private var statusItem: NSStatusItem?

    init(demo: Bool, setup: Bool = false) {
        self.demo = demo
        forceSetup = setup
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
            startConversation(settings)
        }
    }

    private var isConversing: Bool { conversation != nil || liveConversation != nil }

    @objc private func showSetup() {
        guard setup == nil else { return }
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

    private func startConversation(_ settings: AssistantSettings) {
        guard let model, let bridge, !isConversing else { return }
        model.assistantName = settings.assistantName
        SessionFiles.write(settings: settings)

        // One engine for the microphone and the voice, so the echo canceller
        // knows what is being played.
        let engine = AVAudioEngine()
        if settings.voiceEngine == "live" {
            if let key = Secrets.openAIKey {
                Log.write("voice: live")
                let live = LiveConversation(settings: settings, model: model, bridge: bridge, key: key, engine: engine)
                live.start()
                liveConversation = live
                return
            }
            Log.write("the live voice needs an OpenAI key; using the local voice")
        }
        let system = SystemVoice()
        let voice: Voice
        if let key = Secrets.rimeKey {
            voice = RimeVoice(key: key, speaker: settings.rimeSpeaker, language: settings.language, engine: engine, fallback: system)
            Log.write("voice: Rime")
        } else {
            voice = system
            Log.write("voice: system (\(system.voiceName)); no Rime key stored")
        }
        let conversation = Conversation(settings: settings, model: model, bridge: bridge, voice: voice, engine: engine)
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
            let setupItem = NSMenuItem(title: "Setup\u{2026}", action: #selector(showSetup), keyEquivalent: ",")
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

    static var helperPath: String {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.deletingLastPathComponent().appendingPathComponent("assistant-channel").path
    }

    static func write(settings: AssistantSettings) {
        let data = SessionCommand.mcpConfig(helperPath: helperPath, assistantName: settings.assistantName,
                                            socketPath: UnixSocket.standardPath)
        try? FileManager.default.createDirectory(at: SettingsStore.standard.directory, withIntermediateDirectories: true)
        try? data.write(to: mcpConfig, options: .atomic)
        let voiceLayer = settings.voiceEngine == "live" && Secrets.openAIKey != nil
        try? Data(Persona.instructions(name: settings.assistantName, voiceLayer: voiceLayer).utf8).write(to: persona, options: .atomic)
    }

    static func session(settings: AssistantSettings) -> SessionCommand {
        SessionCommand(assistantName: settings.assistantName, model: settings.model, mcpConfigPath: mcpConfig.path, personaPath: persona.path)
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
