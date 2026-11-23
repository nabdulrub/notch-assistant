import Foundation

/// How work is handed out: how much the session does itself, where its workers
/// run, on which models, and how many at once.
public struct Delegation: Codable, Equatable, Sendable {
    public enum Style: String, Codable, CaseIterable, Sendable {
        /// It never does the work itself, not even a one-line check.
        case always
        /// It may take a quick read-only look; everything else is handed over.
        case quickLooks
        /// It does small jobs itself and hands over the bigger ones.
        case handsOn
    }

    public enum Runner: String, Codable, CaseIterable, Sendable {
        /// herdr agents inside herdr, background subagents anywhere else.
        case auto
        case herdr
        case subagents
    }

    public static let mostWorkers = 8

    public var style: Style
    public var runner: Runner
    /// The model workers do real work on. Empty leaves it to the user's own
    /// Claude instructions.
    public var workerModel: String
    /// The model for small mechanical jobs and lookups. Empty, the same.
    public var lightWorkerModel: String
    public var maxWorkers: Int
    /// Whether it asks out loud before sending input to an agent it did not start.
    public var askBeforeTouchingOthers: Bool
    /// Whether it talks a job through before starting it: asks what it needs to
    /// know instead of deciding for the user. Off, it starts at once.
    public var talksItThrough: Bool

    public init(style: Style = .always, runner: Runner = .auto, workerModel: String = "", lightWorkerModel: String = "",
                maxWorkers: Int = 3, askBeforeTouchingOthers: Bool = true, talksItThrough: Bool = true) {
        self.style = style
        self.runner = runner
        self.workerModel = workerModel
        self.lightWorkerModel = lightWorkerModel
        self.maxWorkers = min(max(maxWorkers, 1), Self.mostWorkers)
        self.askBeforeTouchingOthers = askBeforeTouchingOthers
        self.talksItThrough = talksItThrough
    }

    /// Like the settings as a whole, every field is optional on disk, and a
    /// value it does not know falls back to the default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Delegation()
        style = (try? container.decodeIfPresent(Style.self, forKey: .style)) ?? fallback.style
        runner = (try? container.decodeIfPresent(Runner.self, forKey: .runner)) ?? fallback.runner
        workerModel = (try? container.decodeIfPresent(String.self, forKey: .workerModel)) ?? fallback.workerModel
        lightWorkerModel = (try? container.decodeIfPresent(String.self, forKey: .lightWorkerModel)) ?? fallback.lightWorkerModel
        let most = (try? container.decodeIfPresent(Int.self, forKey: .maxWorkers)) ?? fallback.maxWorkers
        maxWorkers = min(max(most, 1), Self.mostWorkers)
        askBeforeTouchingOthers = (try? container.decodeIfPresent(Bool.self, forKey: .askBeforeTouchingOthers)) ?? fallback.askBeforeTouchingOthers
        talksItThrough = (try? container.decodeIfPresent(Bool.self, forKey: .talksItThrough)) ?? fallback.talksItThrough
    }
}

/// Everything the user can change. Stored as one JSON file; there is no database.
public struct AssistantSettings: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// It listens for its name and talks back.
        case voice
        /// No microphone and no sound: the agents' statuses in the notch, and a
        /// chat that is typed.
        case text
    }

    /// Whether it is talked to or typed to.
    public var mode: Mode
    /// Whether the notch is part of what a shared or recorded screen shows.
    /// Off, nobody on a call sees which agents are running or what they say.
    public var showWhileSharing: Bool
    /// The name it answers to and calls itself. Drives the wake word, the persona
    /// and every label in the UI.
    public var assistantName: String
    /// Other spellings speech recognition produces for the name.
    public var wakeAliases: [String]
    /// The shortcut that stands in for saying the name.
    public var talkKey: KeyCombo
    /// The Claude model the orchestrator session runs on.
    public var model: String
    /// The language it listens in, as a BCP 47 tag.
    public var language: String
    /// The folder the orchestrator session starts in.
    public var workingDirectory: String
    /// Seconds between spoken updates while its workers are busy. 0 turns them off.
    public var updateEvery: Double
    /// Which voice model does the listening and talking, and hands work to the
    /// session. "live": OpenAI's, with the user's own key. "sophon": an open
    /// model that runs on this Mac and needs no key.
    public var voiceEngine: String
    /// The voice the live engine speaks with.
    public var liveVoice: String
    /// Seconds of quiet before the line to the voice model is closed. OpenAI's
    /// is billed while open.
    public var liveIdle: Double
    /// With the voice on this Mac: listen only to the voice that said the name,
    /// and take anyone else, a television or a noise for the room.
    public var onlyMyVoice: Bool
    /// How work is handed out to workers.
    public var delegation: Delegation
    /// Who it is and how it sounds, in the user's own words. Empty is the
    /// character it ships with.
    public var personality: String
    /// The user's own rules, added after everything else the session is told.
    public var customInstructions: String
    /// False until the first-run setup has been finished once.
    public var setupDone: Bool

    public init(assistantName: String = "Jarvis", wakeAliases: [String] = [], talkKey: KeyCombo = .defaultTalk,
                model: String = "sonnet", language: String = "en-US",
                workingDirectory: String = "~/Desktop/dev", updateEvery: Double = 40,
                voiceEngine: String = "live", liveVoice: String = "marin", liveIdle: Double = 15, onlyMyVoice: Bool = true,
                delegation: Delegation = Delegation(), personality: String = "", customInstructions: String = "",
                setupDone: Bool = false, mode: Mode = .voice, showWhileSharing: Bool = false) {
        self.mode = mode
        self.showWhileSharing = showWhileSharing
        self.assistantName = assistantName
        self.wakeAliases = wakeAliases
        self.talkKey = talkKey
        self.model = model
        self.language = language
        self.workingDirectory = workingDirectory
        self.updateEvery = updateEvery
        self.voiceEngine = voiceEngine
        self.liveVoice = liveVoice
        self.liveIdle = liveIdle
        self.onlyMyVoice = onlyMyVoice
        self.delegation = delegation
        self.personality = personality
        self.customInstructions = customInstructions
        self.setupDone = setupDone
    }

    /// Every field is optional on disk, so an older or hand-edited file still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = AssistantSettings()
        assistantName = AssistantSettings.cleaned(
            name: try container.decodeIfPresent(String.self, forKey: .assistantName) ?? fallback.assistantName)
        wakeAliases = try container.decodeIfPresent([String].self, forKey: .wakeAliases) ?? fallback.wakeAliases
        talkKey = try container.decodeIfPresent(KeyCombo.self, forKey: .talkKey) ?? fallback.talkKey
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? fallback.model
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? fallback.language
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory) ?? fallback.workingDirectory
        updateEvery = try container.decodeIfPresent(Double.self, forKey: .updateEvery) ?? fallback.updateEvery
        // Anything else is a value from an engine that no longer exists.
        voiceEngine = try container.decodeIfPresent(String.self, forKey: .voiceEngine) == "sophon" ? "sophon" : "live"
        liveVoice = try container.decodeIfPresent(String.self, forKey: .liveVoice) ?? fallback.liveVoice
        liveIdle = try container.decodeIfPresent(Double.self, forKey: .liveIdle) ?? fallback.liveIdle
        onlyMyVoice = try container.decodeIfPresent(Bool.self, forKey: .onlyMyVoice) ?? fallback.onlyMyVoice
        delegation = (try? container.decodeIfPresent(Delegation.self, forKey: .delegation)) ?? fallback.delegation
        personality = try container.decodeIfPresent(String.self, forKey: .personality) ?? fallback.personality
        customInstructions = try container.decodeIfPresent(String.self, forKey: .customInstructions) ?? fallback.customInstructions
        setupDone = try container.decodeIfPresent(Bool.self, forKey: .setupDone) ?? fallback.setupDone
        mode = (try? container.decodeIfPresent(Mode.self, forKey: .mode)) ?? fallback.mode
        showWhileSharing = (try? container.decodeIfPresent(Bool.self, forKey: .showWhileSharing)) ?? fallback.showWhileSharing
    }

    /// Whether the app itself has to start again for a change to take hold.
    /// What only the session is told does not count: that is sent to it.
    public func needsRestart(toBecome other: AssistantSettings) -> Bool {
        assistantName != other.assistantName || wakeAliases != other.wakeAliases || talkKey != other.talkKey
            || language != other.language || updateEvery != other.updateEvery || voiceEngine != other.voiceEngine
            || liveVoice != other.liveVoice || liveIdle != other.liveIdle || onlyMyVoice != other.onlyMyVoice
            || (other.voiceEngine == "live" && personality != other.personality) || mode != other.mode
    }

    /// An empty name would make every sentence a wake word.
    public static func cleaned(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Jarvis" : trimmed
    }
}

public struct SettingsStore: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The folder name is fixed so that renaming the assistant never orphans its
    /// settings.
    ///
    /// `NOTCH_ASSISTANT_HOME` points a copy at a folder of its own, so one
    /// being worked on can run beside the one in use without sharing its
    /// settings, its socket or its lock.
    public static var standard: SettingsStore {
        if let home = ProcessInfo.processInfo.environment["NOTCH_ASSISTANT_HOME"], !home.isEmpty {
            return SettingsStore(directory: URL(fileURLWithPath: (home as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(directory: base.appendingPathComponent("NotchAssistant", isDirectory: true))
    }

    var file: URL { directory.appendingPathComponent("settings.json") }

    public func load() -> AssistantSettings {
        guard let data = try? Data(contentsOf: file),
              let settings = try? JSONDecoder().decode(AssistantSettings.self, from: data) else {
            return AssistantSettings()
        }
        return settings
    }

    public func save(_ settings: AssistantSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }
}
