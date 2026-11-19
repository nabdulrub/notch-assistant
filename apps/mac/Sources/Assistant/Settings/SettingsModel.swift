import AppKit
import AssistantCore
import SwiftUI

@MainActor
final class SettingsModel: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case general, voice, delegation, persona, instructions

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    @Published var section: Section = .general
    @Published var draft: AssistantSettings
    /// What happened to the last save, in a sentence.
    @Published var note: String?
    @Published var recordingKey = false
    @Published var copiedPrompt = false
    /// Where the eyes are on screen, so they can follow the pointer.
    @Published var anchor: CGPoint = .zero

    /// Puts the saved settings to work, and answers with what became of them.
    var onSave: ((_ old: AssistantSettings, _ new: AssistantSettings) -> String)?
    var onOpenSetup: (() -> Void)?

    private(set) var saved: AssistantSettings
    private var keyMonitor: Any?

    init(settings: AssistantSettings) {
        saved = settings
        draft = settings
    }

    /// The draft as it would be written: names and models trimmed, and nothing
    /// left empty that has to have a value.
    var cleaned: AssistantSettings {
        var settings = draft
        settings.assistantName = AssistantSettings.cleaned(name: settings.assistantName)
        let model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.model = model.isEmpty ? AssistantSettings().model : model
        settings.delegation.workerModel = settings.delegation.workerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.delegation.lightWorkerModel = settings.delegation.lightWorkerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.personality = settings.personality.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.customInstructions = settings.customInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings
    }

    var hasChanges: Bool { cleaned != saved }

    func save() {
        let new = cleaned
        let old = saved
        guard new != old else { return }
        do {
            try SettingsStore.standard.save(new)
        } catch {
            note = "Could not write the settings file."
            return
        }
        saved = new
        draft = new
        note = onSave?(old, new) ?? "Saved."
    }

    func revert() {
        draft = saved
        note = nil
    }

    func stop() {
        stopRecording()
    }

    // MARK: General

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder your projects live in. Claude Code starts here."
        panel.directoryURL = URL(fileURLWithPath: (draft.workingDirectory as NSString).expandingTildeInPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        draft.workingDirectory = (url.path as NSString).abbreviatingWithTildeInPath
    }

    /// The next shortcut pressed becomes the talk key. Escape leaves it as it was.
    func recordKey() {
        guard keyMonitor == nil else { return stopRecording() }
        recordingKey = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                var modifiers: ModifierSet = []
                if event.modifierFlags.contains(.command) { modifiers.insert(.command) }
                if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
                if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
                if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
                let combo = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
                if event.keyCode == Self.escape, modifiers.isEmpty {
                    self.stopRecording()
                } else if combo.isUsable {
                    self.draft.talkKey = combo
                    self.stopRecording()
                }
            }
            return nil
        }
    }

    private static let escape: UInt16 = 53

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingKey = false
    }

    // MARK: Persona and instructions

    func startFromDefault() {
        draft.personality = Persona.defaultCharacter
    }

    /// Everything the session would be told with the settings as they stand.
    func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Persona.instructions(for: cleaned), forType: .string)
        copiedPrompt = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.copiedPrompt = false
        }
    }
}
