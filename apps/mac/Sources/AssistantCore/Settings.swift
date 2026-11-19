import Foundation

/// Everything the user can change. Stored as one JSON file; there is no database.
public struct AssistantSettings: Codable, Equatable, Sendable {
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
    /// False until the first-run setup has been finished once.
    public var setupDone: Bool

    public init(assistantName: String = "Jarvis", wakeAliases: [String] = [], talkKey: KeyCombo = .defaultTalk,
                model: String = "sonnet", language: String = "en-US",
                workingDirectory: String = "~/Desktop/dev", updateEvery: Double = 40,
                voiceEngine: String = "live", liveVoice: String = "marin", liveIdle: Double = 15,
                setupDone: Bool = false) {
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
        setupDone = try container.decodeIfPresent(Bool.self, forKey: .setupDone) ?? fallback.setupDone
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
    public static var standard: SettingsStore {
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
