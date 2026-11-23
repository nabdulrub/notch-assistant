import AppKit
import AssistantCore
import Sparkle

/// Keeps the app on the latest version. Sparkle looks at the feed every few
/// hours, downloads a new version in the background and checks that it was
/// signed with the key this copy was built with. The app then starts again on
/// it at the first quiet moment, so nobody is cut off in the middle of
/// something and nobody is asked anything.
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController?
    /// Installs what was downloaded and starts the app again.
    private var install: (() -> Void)?
    private var waiting: Timer?
    /// Asked before installing. See `UpdateMoment`.
    var moment: () -> UpdateMoment = { UpdateMoment() }

    /// Only a bundled build knows where its feed is and which key signs it.
    /// One run straight from the build folder has neither, and is left alone.
    static var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    func start() {
        guard Self.isConfigured, controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        do {
            try controller.updater.start()
        } catch {
            Log.write("version \(Self.version); updates are off: \(error.localizedDescription)")
            return
        }
        self.controller = controller
        Log.write("version \(Self.version); updates are checked for in the background")
    }

    var isRunning: Bool { controller != nil }

    /// From the menu: looks now and says what it found.
    @objc func checkNow() {
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Log.write("update: version \(item.displayVersionString) is out")
    }

    nonisolated func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        Log.write("update: looking again in \(Int(delay / 60)) minutes")
    }

    nonisolated func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        Log.write("update: checking is turned off for this copy")
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // "Up to date" arrives here too, and is not worth a line.
        let problem = error as NSError
        guard !(problem.domain == SUSparkleErrorDomain && problem.code == 1001) else { return }
        Log.write("update: \(problem.localizedDescription)")
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            Log.write("update: version \(version) is downloaded and checked; starting again on it at the next quiet moment")
            install = immediateInstallHandler
            waitForQuiet()
        }
        return true
    }

    private func waitForQuiet() {
        waiting?.invalidate()
        waiting = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
    }

    private func installIfQuiet() {
        guard let install, moment().isQuiet else { return }
        waiting?.invalidate()
        waiting = nil
        Log.write("update: starting again on the new version")
        install()
    }
}
