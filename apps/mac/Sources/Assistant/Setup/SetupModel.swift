import AVFoundation
import AppKit
import AssistantCore
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case name, voice, microphone, session, ready
    }

    enum KeyState: Equatable {
        case empty
        /// One is already stored on this Mac.
        case saved
        case checking
        case good
        case bad(String)

        var isUsable: Bool { self == .saved || self == .good }
    }


    static let liveVoices = [
        "marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon",
        "delta", "cinder", "nuri", "juni", "flitz", "brise", "sillage", "nira", "harema", "shida", "noeul",
    ]

    @Published var step: Step = .name
    @Published var name: String
    @Published var engine: String
    @Published var liveVoice: String
    @Published var openAIKey = ""
    @Published var openAIState: KeyState
    /// Whether the model that runs on this Mac has been installed.
    @Published var localModelInstalled: Bool
    @Published var copiedInstall = false
    @Published var microphone: AVAuthorizationStatus
    @Published var sessionAttached = false
    @Published var startingSession = false
    @Published var sessionProblem: String?
    @Published var copied = false
    /// The folder the session starts in, written with a tilde.
    @Published var workingDirectory: String
    /// Nil until it has been looked for.
    @Published var claudeInstalled: Bool?
    /// Where the eyes are on screen, so they can follow the pointer.
    @Published var anchor: CGPoint = .zero

    let herdrPath = SessionStarter.herdrPath
    var onFinish: (() -> Void)?

    private(set) var settings: AssistantSettings
    private let bridge: BridgeServer?
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init(settings: AssistantSettings, bridge: BridgeServer?) {
        self.settings = settings
        self.bridge = bridge
        name = settings.assistantName
        engine = settings.voiceEngine
        liveVoice = settings.liveVoice
        openAIState = Secrets.openAIKey == nil ? .empty : .saved
        localModelInstalled = SophonServer.install() != nil
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        // The default suits the machine it was written on; anywhere else, start at home.
        let folder = (settings.workingDirectory as NSString).expandingTildeInPath
        var isFolder: ObjCBool = false
        workingDirectory = FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue
            ? settings.workingDirectory : "~"
        Task { [weak self] in
            let installed = await SessionStarter.claudeInstalled()
            self?.claudeInstalled = installed
        }
        sessionAttached = (bridge?.sessionCount ?? 0) > 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Coming back from System Settings, the answer may have changed.
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func refresh() {
        let attached = (bridge?.sessionCount ?? 0) > 0
        if attached != sessionAttached { sessionAttached = attached }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status != microphone { microphone = status }
        if step == .voice, engine == "sophon" {
            let installed = SophonServer.install() != nil
            if installed != localModelInstalled { localModelInstalled = installed }
        }
    }

    // MARK: What the eyes do

    var eyes: Phase {
        if openAIState == .checking || startingSession { return .thinking }
        switch step {
        case .name, .microphone: return .listening
        case .voice, .ready: return .followUp
        case .session: return sessionAttached ? .followUp : .thinking
        }
    }

    // MARK: Moving through the steps

    var cleanName: String { AssistantSettings.cleaned(name: name) }

    var canContinue: Bool {
        switch step {
        case .name:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .voice:
            // The voice on this Mac needs no key, only its model.
            if engine == "sophon" { return localModelInstalled }
            switch openAIState {
            case .checking, .bad: return false
            case .saved, .good: return true
            case .empty: return !openAIKey.isEmpty
            }
        case .microphone, .session, .ready:
            return true
        }
    }

    var progress: Double { Double(step.rawValue + 1) / Double(Step.allCases.count) }

    func next() {
        guard canContinue else { return }
        if step == .voice, engine == "live", !openAIKey.isEmpty, openAIState == .empty {
            // A key that was typed but never checked is checked on the way out.
            Task {
                await checkKey()
                if openAIState == .good { advance() }
            }
            return
        }
        advance()
    }

    private func advance() {
        save()
        guard let following = Step(rawValue: step.rawValue + 1) else {
            settings.setupDone = true
            save()
            onFinish?()
            return
        }
        step = following
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// Written after every step, so the session files always match the choices
    /// made so far by the time the session is started.
    private func save() {
        settings.assistantName = cleanName
        settings.voiceEngine = engine
        settings.liveVoice = liveVoice
        settings.workingDirectory = workingDirectory
        try? SettingsStore.standard.save(settings)
        SessionFiles.write(settings: settings)
    }

    // MARK: Keys

    func keyEdited() {
        guard openAIState != .checking else { return }
        openAIState = openAIKey.isEmpty && Secrets.openAIKey != nil ? .saved : .empty
    }

    func checkKey() async {
        let key = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        openAIState = .checking
        if let problem = await KeyCheck.openAI(key) {
            openAIState = .bad(problem)
        } else {
            openAIState = (try? Secrets.storeOpenAIKey(key)) == nil ? .bad("The key works but could not be saved on this Mac.") : .good
        }
    }

    // MARK: The model on this Mac

    func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SophonServer.installCommand, forType: .string)
        copiedInstall = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copiedInstall = false
        }
    }

    // MARK: Microphone

    func askForMicrophone() {
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: The Claude Code session

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder your projects live in. Claude Code starts here."
        panel.directoryURL = URL(fileURLWithPath: (workingDirectory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workingDirectory = (url.path as NSString).abbreviatingWithTildeInPath
        save()
    }

    func copyCommand() {
        save()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(SessionFiles.command(settings: settings), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    func startSession() {
        guard let herdrPath, !startingSession else { return }
        save()
        startingSession = true
        sessionProblem = nil
        let directory = (settings.workingDirectory as NSString).expandingTildeInPath
        let arguments = Array(SessionFiles.arguments(settings: settings).dropFirst())
        let name = settings.assistantName
        Task {
            sessionProblem = await SessionStarter.start(herdr: herdrPath, name: name, directory: directory, arguments: arguments)
            startingSession = false
            refresh()
        }
    }
}
