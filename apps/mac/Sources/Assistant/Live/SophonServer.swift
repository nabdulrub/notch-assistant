import AssistantCore
import Foundation

/// The voice model that runs on this Mac: Sophon-Realtime, an open model that
/// listens and talks by itself. It is loaded once when the app starts, which
/// takes about ten seconds, and kept until the app quits. Loaded, it holds
/// about 9 GB of memory.
///
/// The model and its Python environment are installed by the user with
/// Sophon's own installer; this only finds them and runs the bridge on top.
@MainActor
final class SophonServer {
    static let port = 8791
    /// What is pasted into a terminal to install it.
    static let installCommand =
        "git clone --depth 1 https://github.com/adventists-ai/sophon-realtime ~/sophon-realtime && SIZE=4B bash ~/sophon-realtime/mac/install.sh"

    struct Install {
        let python: URL
        let app: URL
        let models: URL
    }

    private static var home: URL {
        if let chosen = ProcessInfo.processInfo.environment["SOPHON_HOME"], !chosen.isEmpty {
            return URL(fileURLWithPath: (chosen as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sophon-mac", isDirectory: true)
    }

    /// Nil until the installer has finished its download.
    static func install() -> Install? {
        let files = FileManager.default
        let python = home.appendingPathComponent(".venv/bin/python")
        let app = home.appendingPathComponent("app", isDirectory: true)
        guard files.isExecutableFile(atPath: python.path),
              files.fileExists(atPath: app.appendingPathComponent("engine.py").path) else { return nil }
        // The small model first: it is the one that fits next to everything else.
        for folder in ["models-4b", "models"] {
            let models = home.appendingPathComponent(folder, isDirectory: true)
            if files.fileExists(atPath: models.appendingPathComponent(".complete").path) {
                return Install(python: python, app: app, models: models)
            }
        }
        return nil
    }

    private static var bridge: URL? {
        if let bundled = Bundle.main.url(forResource: "sophon_bridge", withExtension: "py") { return bundled }
        // Run straight from the build folder, the script is still in the repo.
        let inRepo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/sophon_bridge.py")
        return FileManager.default.fileExists(atPath: inRepo.path) ? inRepo : nil
    }

    private var process: Process?

    /// - Parameter onlyOwner: listen only to the voice that said the name, where the speaker model is installed.
    func start(name: String, onlyOwner: Bool = true) -> Bool {
        guard process == nil else { return true }
        guard let install = Self.install(), let bridge = Self.bridge else { return false }
        let directory = SettingsStore.standard.directory
        let prompt = directory.appendingPathComponent("sophon-prompt.json")
        let log = directory.appendingPathComponent("sophon.log")
        guard let instructions = try? JSONSerialization.data(withJSONObject: ["en": LivePersona.onDevice(name: name)]),
              (try? instructions.write(to: prompt, options: .atomic)) != nil else { return false }
        FileManager.default.createFile(atPath: log.path, contents: nil)

        let task = Process()
        task.executableURL = install.python
        task.arguments = [
            bridge.path, "--app", install.app.path, "--root", install.models.path, "--prompt", prompt.path,
            "--port", String(Self.port), "--parent", String(ProcessInfo.processInfo.processIdentifier),
        ] + (onlyOwner ? [] : ["--any-voice"])
        task.currentDirectoryURL = directory
        if let output = try? FileHandle(forWritingTo: log) {
            task.standardOutput = output
            task.standardError = output
        }
        task.terminationHandler = { ended in
            Log.write("the model on this Mac stopped (\(ended.terminationStatus)); see sophon.log next to this log")
        }
        do {
            try task.run()
        } catch {
            Log.write("could not start the model on this Mac: \(error.localizedDescription)")
            return false
        }
        process = task
        Log.write("loading the model on this Mac from \(install.models.lastPathComponent)")
        return true
    }

    func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
    }
}
