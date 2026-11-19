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

/// A borderless panel above the menu bar. It never takes focus, so talking to the
/// assistant does not pull you out of the app you are in.
final class NotchPanel: NSPanel {
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

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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

    init(model: NotchModel) {
        self.model = model
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        place()
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
        let size = model.size
        return NSRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
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
