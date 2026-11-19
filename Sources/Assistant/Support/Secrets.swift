import AssistantCore
import Foundation

/// The Rime key, kept in a file only this user can read.
///
/// It belongs in the Keychain, and will move there once the app is signed with a
/// real identity. With an ad hoc signature the Keychain treats every rebuild as a
/// different app and asks for the login password each time.
enum Secrets {
    private static var rimeFile: URL { SettingsStore.standard.directory.appendingPathComponent("rime.key") }

    static var rimeKey: String? {
        if let fromEnvironment = ProcessInfo.processInfo.environment["RIME_API_KEY"], !fromEnvironment.isEmpty {
            return fromEnvironment
        }
        guard let data = try? Data(contentsOf: rimeFile), let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var openAIFile: URL { SettingsStore.standard.directory.appendingPathComponent("openai.key") }

    static var openAIKey: String? { read(openAIFile, environment: "OPENAI_API_KEY") }

    static func storeOpenAIKey(_ key: String) throws { try store(key, in: openAIFile) }

    private static func read(_ file: URL, environment: String) -> String? {
        if let value = ProcessInfo.processInfo.environment[environment], !value.isEmpty { return value }
        guard let data = try? Data(contentsOf: file), let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func store(_ key: String, in file: URL) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: file.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    static func storeRimeKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: rimeFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: rimeFile.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rimeFile.path)
    }
}
