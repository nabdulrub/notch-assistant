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
        for (position, step) in DemoStep.script(name: name).enumerated() {
            let model = NotchModel(assistantName: name)
            model.metrics = metrics
            step.apply(to: model)
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.72, green: 0.66, blue: 0.6)],
                               startPoint: .top, endPoint: .bottom)
                IslandView(model: model, frozenTime: 2.0)
            }
            .frame(width: NotchLayout.canvasWidth, height: NotchLayout.canvasHeight)

            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let file = directory.appendingPathComponent(String(format: "%02d-%@.png", position + 1, step.name))
            try png.write(to: file)
            written.append(file)
        }
        return written
    }

    /// The setup screens, one PNG each. These hold real text fields and menus,
    /// which only draw inside a window, so they are drawn in one that is never
    /// put on screen.
    static func setup(directory: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for step in SetupModel.Step.allCases {
            let model = SetupModel(settings: AssistantSettings(), bridge: nil)
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
            let file = directory.appendingPathComponent("setup-\(step.rawValue + 1)-\(step).png")
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
