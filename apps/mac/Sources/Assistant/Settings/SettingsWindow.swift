import AppKit
import AssistantCore
import SwiftUI

/// Owns the settings window. Like setup, the app is an ordinary one while it is
/// open, so that typing and pasting work.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let model: SettingsModel
    private let window: NSWindow
    private let onClose: () -> Void

    init(settings: AssistantSettings, onClose: @escaping () -> Void) {
        model = SettingsModel(settings: settings)
        self.onClose = onClose
        window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.delegate = self
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = SetupWindowController.menu(name: model.saved.assistantName)
        window.center()
        placeEyes()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.close()
    }

    func windowDidMove(_ notification: Notification) {
        placeEyes()
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        NSApp.setActivationPolicy(.accessory)
        onClose()
    }

    private func placeEyes() {
        model.anchor = CGPoint(x: window.frame.minX + 98, y: window.frame.maxY - 84)
    }
}
