import AppKit
import AssistantCore
import SwiftUI

/// Renders every step of the demo script to a PNG, offscreen. It needs no screen
/// recording permission and gives the same pixels every run, so the look can be
/// reviewed and compared without watching the live overlay.
@MainActor
enum Snapshot {
    static func run(directory: URL, name: String, metrics: NotchMetrics) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (position, step) in (DemoStep.script(name: name) + DemoStep.textScript(name: name)).enumerated() {
            let model = NotchModel(assistantName: name)
            model.metrics = metrics
            step.apply(to: model)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.72, green: 0.66, blue: 0.6)],
                               startPoint: .top, endPoint: .bottom)
                IslandView(model: model, frozenTime: 2.0)
            }
            .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)

            let png: Data
            if step.text != nil {
                // The chat scrolls and has a text field, and those only draw
                // inside a window.
                png = try inWindow(view, size: CGSize(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight))
            } else {
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let data = bitmap.representation(using: .png, properties: [:]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                png = data
            }
            let file = directory.appendingPathComponent(String(format: "%02d-%@.png", position + 1, step.name))
            try png.write(to: file)
            written.append(file)
        }
        return written
    }

    /// Draws a view in a window that is never put on screen.
    private static func inWindow(_ view: some View, size: CGSize) throws -> Data {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // One turn of the run loop, for what is laid out only once it is in a window.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    /// The setup screens, one PNG each. These hold real text fields and menus,
    /// which only draw inside a window, so they are drawn in one that is never
    /// put on screen.
    static func setup(directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        let pages = SetupStep.steps(for: .voice).map { (AssistantSettings.Mode.voice, $0) }
            + SetupStep.steps(for: .text).map { (AssistantSettings.Mode.text, $0) }
        for (index, (mode, step)) in pages.enumerated() {
            let model = SetupModel(settings: AssistantSettings(mode: mode), bridge: nil)
            model.step = step
            model.stop()
            let view = SetupView(model: model, frozenTime: 2.0)
                .background(LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.32), Color(red: 0.3, green: 0.26, blue: 0.24)],
                                           startPoint: .top, endPoint: .bottom))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SetupView.size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let file = directory.appendingPathComponent(String(format: "setup-%02d-\(mode)-\(step).png", index + 1))
            try png.write(to: file)
            written.append(file)
        }
        return written
    }

    /// Each section of the settings window, with a persona and a rule written
    /// in so the editors are seen holding something.
    static func settings(directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for (index, section) in SettingsModel.Section.allCases.enumerated() {
            let model = SettingsModel(settings: AssistantSettings(voiceEngine: "live"))
            model.section = section
            model.draft.delegation.workerModel = "sonnet"
            model.draft.delegation.lightWorkerModel = "haiku"
            model.draft.personality = "You are calm and precise, a little formal, and you never joke about prod."
            model.draft.customInstructions = "Open every pull request as a draft.\nNever touch the main checkout."
            let view = SettingsView(model: model, frozenTime: 2.0)
                .background(LinearGradient(colors: [Color(red: 0.2, green: 0.24, blue: 0.32), Color(red: 0.3, green: 0.26, blue: 0.24)],
                                           startPoint: .top, endPoint: .bottom))
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            let file = directory.appendingPathComponent("settings-\(index + 1)-\(section.rawValue).png")
            try png.write(to: file)
            written.append(file)
        }
        return written
    }

    /// The app icon: the eyes on the island's black, at the size macOS asks for.
    static func icon(to file: URL) throws {
        let view = ZStack {
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color.black], startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 185, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 3))
                .frame(width: 824, height: 824)
                .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            HStack(spacing: 116) {
                ForEach(0..<2, id: \.self) { _ in
                    Capsule(style: .continuous)
                        .fill(LinearGradient(colors: [Color.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 118, height: 218)
                        .shadow(color: Color.white.opacity(0.55), radius: 16)
                        .shadow(color: Color.white.opacity(0.3), radius: 60)
                }
            }
        }
        .frame(width: 1024, height: 1024)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: file)
    }
}
