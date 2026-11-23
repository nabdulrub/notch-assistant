import AppKit
import AssistantCore
import Combine
import SwiftUI

enum NotchGeometry {
    /// The built-in display if it has a notch, otherwise wherever the menu bar is.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The notch is whatever the two menu bar areas beside it leave uncovered.
    static func metrics(for screen: NSScreen) -> NotchMetrics {
        let height = screen.safeAreaInsets.top
        guard height > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
            return .floating
        }
        let width = screen.frame.width - left.width - right.width
        guard width > 0 else { return .floating }
        return NotchMetrics(width: width, height: height, hasHardwareNotch: true)
    }

    static func centerX(of screen: NSScreen, metrics: NotchMetrics) -> CGFloat {
        guard metrics.hasHardwareNotch, let left = screen.auxiliaryTopLeftArea else { return screen.frame.midX }
        return screen.frame.minX + left.width + metrics.width / 2
    }
}

/// A borderless panel above the menu bar. It never takes focus by itself, so
/// talking to the assistant does not pull you out of the app you are in. Text
/// mode takes the keyboard for as long as its chat is open, and no longer.
final class NotchPanel: NSPanel {
    /// True while the chat is open and being typed in.
    var takesKeyboard = false
    /// Escape, while it has the keyboard.
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// AppKit would otherwise push the panel down below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class NotchController {
    let model: NotchModel
    private let panel = NotchPanel()
    private var observers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var screenFrame: NSRect = .zero
    private var centerX: CGFloat = 0
    private var watching: [AnyCancellable] = []

    /// Whether a shared or recorded screen shows the notch. It starts out left
    /// out of them: what the agents are up to is not for a call to see.
    var shownWhileSharing = false {
        didSet { panel.sharingType = shownWhileSharing ? .readOnly : .none }
    }

    /// Off for the demo, which opens the chat by itself and must not take the
    /// keys from whatever the user is typing in.
    var takesKeyboard = true

    init(model: NotchModel) {
        self.model = model
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        place()
        watchChat()
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.place() }
        })
        watchPointer()
        panel.orderFrontRegardless()
        if !PinnedSpace.pin(panel) { Log.write("could not pin the notch above Spaces; it will blink when you switch desktops") }
    }

    private func place() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let metrics = NotchGeometry.metrics(for: screen)
        model.metrics = metrics
        screenFrame = screen.frame
        centerX = NotchGeometry.centerX(of: screen, metrics: metrics)
        let width = NotchLayout.canvasWidth
        let height = NotchLayout.canvasHeight
        panel.setFrame(NSRect(x: centerX - width / 2, y: screen.frame.maxY - height, width: width, height: height),
                       display: true)
        model.anchor = CGPoint(x: centerX, y: screen.frame.maxY - metrics.height - 23)
    }

    /// The island as it is drawn right now, in screen coordinates.
    private var islandFrame: NSRect {
        let size = model.footprint
        return NSRect(x: centerX + model.size.shift - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// The chat is typed in, so the panel takes the keyboard while it is open
    /// and hands it back the moment it closes. A click anywhere else, another
    /// app coming forward, or Escape closes it.
    private func watchChat() {
        panel.onCancel = { [weak self] in self?.model.close() }
        model.$isOpen.removeDuplicates().dropFirst().sink { [weak self] open in
            guard let self else { return }
            if open { self.takeKeyboard() } else { self.giveUpKeyboard() }
        }.store(in: &watching)
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.close() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.model.isOpen, !self.panel.isKeyWindow else { return }
                self.panel.makeKey()
            }
        })
        if let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.model.close() }
        }) {
            monitors.append(outside)
        }
    }

    private func takeKeyboard() {
        guard takesKeyboard else { return }
        panel.takesKeyboard = true
        // Keys only arrive once the app is the active one, and that takes the
        // system a moment: the panel is made key again when it has happened.
        NSApp.activate()
        panel.makeKey()
    }

    /// Typing needs the app to be the active one, and it stays that way until
    /// it is told otherwise. So closing the chat steps the app back, which
    /// returns the keys to whatever the user was in before. Not while one of
    /// its own windows is open: Settings keeps the keyboard it had.
    private func giveUpKeyboard() {
        panel.takesKeyboard = false
        guard panel.isKeyWindow else { return }
        if let own = NSApp.windows.first(where: { $0 !== panel && $0.isVisible && $0.canBecomeMain }) {
            own.makeKey()
        } else {
            NSApp.deactivate()
        }
    }

    /// The panel is a fixed transparent canvas, larger than the island. It only
    /// accepts the mouse while the pointer is over the island itself, so the menu
    /// bar and everything else under the canvas stay clickable.
    private func watchPointer() {
        let update: () -> Void = { [weak self] in
            guard let self else { return }
            let inside = self.islandFrame.contains(NSEvent.mouseLocation)
            if self.panel.ignoresMouseEvents == inside {
                self.panel.ignoresMouseEvents = !inside
            }
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in
            MainActor.assumeIsolated(update)
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            MainActor.assumeIsolated(update)
            return event
        }) {
            monitors.append(local)
        }
        panel.acceptsMouseMovedEvents = true
    }
}
