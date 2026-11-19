import AssistantCore
import Foundation

/// The user's own OpenAI key, kept in a file only this user can read. The app
/// ships with no key of its own and never sends this one anywhere but OpenAI.
///
/// It belongs in the Keychain, and will move there once the app is signed with a
/// real identity. With an ad hoc signature the Keychain treats every rebuild as a
/// different app and asks for the login password each time.
enum Secrets {
    private static var openAIFile: URL { SettingsStore.standard.directory.appendingPathComponent("openai.key") }

    static var openAIKey: String? {
        if let value = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !value.isEmpty { return value }
        guard let data = try? Data(contentsOf: openAIFile), let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func storeOpenAIKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: openAIFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: openAIFile.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: openAIFile.path)
    }
}
