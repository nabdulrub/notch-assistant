import AppKit
import AssistantCore
import SwiftUI

/// Owns the setup window. While it is open the app behaves like an ordinary
/// one, with a Dock icon and an Edit menu, so that pasting a key works; closed,
/// it goes back to living only in the notch.
@MainActor
final class SetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: SetupModel
    private let onClose: (_ finished: Bool) -> Void
    private var finished = false

    init(settings: AssistantSettings, bridge: BridgeServer?, onClose: @escaping (_ finished: Bool) -> Void) {
        model = SetupModel(settings: settings, bridge: bridge)
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: SetupView(model: model))
        window.delegate = self
        model.onFinish = { [weak self] in
            self?.finished = true
            self?.window.close()
        }
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = Self.menu(name: model.cleanName)
        window.center()
        placeEyes()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMove(_ notification: Notification) {
        placeEyes()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        NSApp.setActivationPolicy(.accessory)
        onClose(finished)
    }

    private func placeEyes() {
        model.anchor = CGPoint(x: window.frame.midX, y: window.frame.maxY - 94)
    }

    /// Key equivalents come from the menu bar, so without an Edit menu a text
    /// field does not paste.
    private static func menu(name: String) -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
