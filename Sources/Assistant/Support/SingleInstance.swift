import AssistantCore
import Darwin
import Foundation

/// Only one copy runs at a time. A second one would take over the socket the
/// session talks to, and both would listen on the same microphone.
enum SingleInstance {
    /// Held for as long as this process lives; the system lets go of it when
    /// the process ends, however it ends.
    nonisolated(unsafe) private static var descriptor: Int32 = -1

    static func claim() -> Bool {
        let directory = SettingsStore.standard.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = open(directory.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        // Without a lock file there is nothing to go on; better to run than not.
        guard file >= 0 else { return true }
        // A copy that is restarting itself lets go within a moment.
        for _ in 0..<30 {
            if flock(file, LOCK_EX | LOCK_NB) == 0 {
                descriptor = file
                return true
            }
            usleep(100_000)
        }
        close(file)
        return false
    }
}
