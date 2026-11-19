import AppKit

/// Keeps a window out of the Spaces animation.
///
/// A window that merely joins every Space is still taken off screen and put back
/// when you swipe to another desktop or a full-screen app, which is the blink.
/// The window server also has spaces of its own that sit above all of that and
/// do not move; a window placed in one stays exactly where it is. There is no
/// public way to ask for this, so the calls are looked up at run time, and if the
/// system no longer has them the window is simply left as it was.
@MainActor
enum PinnedSpace {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Create = @convention(c) (Int32, Int, CFDictionary?) -> UInt64
    private typealias SetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias Show = @convention(c) (Int32, CFArray) -> Void
    private typealias AddWindows = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static var space: UInt64?

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    /// - Returns: false when the system would not do it.
    @discardableResult
    static func pin(_ window: NSWindow) -> Bool {
        guard let connection = symbol("_CGSDefaultConnection", as: Connection.self),
              let create = symbol("CGSSpaceCreate", as: Create.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = symbol("CGSShowSpaces", as: Show.self),
              let add = symbol("CGSAddWindowsToSpaces", as: AddWindows.self),
              window.windowNumber > 0 else { return false }
        let id = connection()
        if space == nil {
            // The 1 matters: with any other value Finder draws the desktop in it.
            let created = create(id, 1, nil)
            guard created != 0 else { return false }
            setLevel(id, created, Int32.max)
            show(id, [created] as CFArray)
            space = created
        }
        guard let space else { return false }
        add(id, [window.windowNumber] as CFArray, [space] as CFArray)
        return true
    }
}
