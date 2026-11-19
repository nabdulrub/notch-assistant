import AppKit
import ScreenCaptureKit

/// Takes one picture of the screen when the session asks to see it. Nothing is
/// kept: the picture goes to the session and is gone.
enum ScreenEye {
    enum Problem: Error {
        case notAllowed
        case nothingToSee

        /// Written for the session, which passes it on to the user.
        var explanation: String {
            switch self {
            case .notAllowed:
                return "The user has not allowed Notch Assistant to see the screen yet. macOS has just asked them. If they missed it: System Settings, Privacy and Security, Screen and System Audio Recording, turn on Notch Assistant, then open the app again. Tell them that in one line."
            case .nothingToSee:
                return "The screen could not be captured just now. Tell the user in one line and offer to try again."
            }
        }
    }

    /// The longest side of the picture. Larger than this is scaled down again
    /// before the model sees it, so the extra would only be weight.
    private static let longestSide: CGFloat = 1568

    /// The display the pointer is on, without this app's own windows, as a JPEG.
    @MainActor
    static func look() async throws -> Data {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw Problem.notAllowed
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        let wanted = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            Log.write("could not list the screen's contents: \(error.localizedDescription)")
            throw Problem.notAllowed
        }
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first else {
            throw Problem.nothingToSee
        }
        // The notch itself is not what they are asking about.
        let own = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let pixels = CGSize(width: CGFloat(display.width) * filter.pointPixelScale.cg, height: CGFloat(display.height) * filter.pointPixelScale.cg)
        let scale = min(1, longestSide / max(pixels.width, pixels.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Int(pixels.width * scale)
        configuration.height = Int(pixels.height * scale)
        configuration.showsCursor = true

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            Log.write("could not capture the screen: \(error.localizedDescription)")
            throw Problem.nothingToSee
        }
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            throw Problem.nothingToSee
        }
        return jpeg
    }
}

private extension Float {
    var cg: CGFloat { CGFloat(self) }
}
