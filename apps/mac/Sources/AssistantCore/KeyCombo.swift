import Foundation

public struct ModifierSet: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = ModifierSet(rawValue: 1 << 0)
    public static let option = ModifierSet(rawValue: 1 << 1)
    public static let control = ModifierSet(rawValue: 1 << 2)
    public static let shift = ModifierSet(rawValue: 1 << 3)

    public var display: String {
        var out = ""
        if contains(.control) { out += "\u{2303}" }
        if contains(.option) { out += "\u{2325}" }
        if contains(.shift) { out += "\u{21E7}" }
        if contains(.command) { out += "\u{2318}" }
        return out
    }
}

public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Control-Option-Space, the default talk key.
    public static let defaultTalk = KeyCombo(keyCode: KeyCodes.space, modifiers: [.control, .option])

    public var display: String { modifiers.display + KeyCodes.name(for: keyCode) }

    /// A hotkey with no modifier would swallow an ordinary keystroke system-wide.
    public var isUsable: Bool { !modifiers.isEmpty || KeyCodes.isFunctionKey(keyCode) }
}

public enum KeyCodes {
    public static let a: UInt16 = 0
    public static let d: UInt16 = 2
    public static let m: UInt16 = 46
    public static let space: UInt16 = 49

    private static let names: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
        20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
        29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "\u{21A9}",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 48: "\u{21E5}", 49: "Space", 50: "`", 51: "\u{232B}", 53: "\u{238B}",
        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
        109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "\u{2190}",
        124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    public static func name(for keyCode: UInt16) -> String {
        names[keyCode] ?? "Key \(keyCode)"
    }

    public static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [96, 97, 98, 99, 100, 101, 103, 109, 111, 118, 120, 122].contains(keyCode)
    }
}
