import Foundation

/// One line on the socket between the app and the channel helper that Claude Code
/// spawns. Newline-delimited JSON, flat on purpose so either side can be poked
/// with `nc` while debugging.
public struct BridgeMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// helper -> app: a session is attached.
        case hello
        /// helper -> app: say this out loud.
        case speak
        /// helper -> app: show this silently in the notch.
        case show
        /// helper -> app: the session is waiting on a permission prompt.
        case permissionRequest
        /// app -> helper: something the user said or typed.
        case utterance
        /// app -> helper: something that happened (an agent changed state, the user cut in).
        case event
        /// app -> helper: the user's answer to a permission prompt.
        case permissionVerdict
        /// helper -> app: the session asked to see the screen.
        case look
        /// app -> helper: the screen as a picture, or why there is none.
        case screen
        /// herdr plugin -> app: an agent just changed state, so look now and not at the next poll.
        case nudge
    }

    public var type: Kind
    public var text: String?
    public var title: String?
    public var detail: String?
    public var expectReply: Bool?
    public var requestId: String?
    public var tool: String?
    public var allow: Bool?
    public var kind: String?
    public var meta: [String: String]?
    /// A JPEG, base64 encoded.
    public var image: String?

    public init(type: Kind, text: String? = nil, title: String? = nil, detail: String? = nil,
                expectReply: Bool? = nil, requestId: String? = nil, tool: String? = nil,
                allow: Bool? = nil, kind: String? = nil, meta: [String: String]? = nil, image: String? = nil) {
        self.type = type
        self.text = text
        self.title = title
        self.detail = detail
        self.expectReply = expectReply
        self.requestId = requestId
        self.tool = tool
        self.allow = allow
        self.kind = kind
        self.meta = meta
        self.image = image
    }

    public static let hello = BridgeMessage(type: .hello)
    public static let nudge = BridgeMessage(type: .nudge)

    public static func speak(_ text: String, expectReply: Bool = false) -> BridgeMessage {
        BridgeMessage(type: .speak, text: text, expectReply: expectReply)
    }

    public static func show(title: String, detail: String) -> BridgeMessage {
        BridgeMessage(type: .show, title: title, detail: detail)
    }

    public static func permissionRequest(id: String, tool: String, summary: String, preview: String) -> BridgeMessage {
        BridgeMessage(type: .permissionRequest, text: summary, detail: preview, requestId: id, tool: tool)
    }

    public static func utterance(_ text: String, source: String) -> BridgeMessage {
        BridgeMessage(type: .utterance, text: text, kind: source)
    }

    public static func event(kind: String, text: String, meta: [String: String] = [:]) -> BridgeMessage {
        BridgeMessage(type: .event, text: text, kind: kind, meta: meta)
    }

    public static func permissionVerdict(requestId: String, allow: Bool) -> BridgeMessage {
        BridgeMessage(type: .permissionVerdict, requestId: requestId, allow: allow)
    }

    /// - Parameter requestId: names the tool call to answer, and comes back
    ///   unchanged with the picture.
    public static func look(requestId: String) -> BridgeMessage {
        BridgeMessage(type: .look, requestId: requestId)
    }

    public static func screen(requestId: String, jpeg: Data) -> BridgeMessage {
        BridgeMessage(type: .screen, requestId: requestId, image: jpeg.base64EncodedString())
    }

    /// - Parameter problem: why there is no picture, written for the session to act on.
    public static func noScreen(requestId: String, problem: String) -> BridgeMessage {
        BridgeMessage(type: .screen, text: problem, requestId: requestId)
    }

    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)) ?? Data("{}".utf8)
    }

    public static func decode(_ line: Data) -> BridgeMessage? {
        try? JSONDecoder().decode(BridgeMessage.self, from: line)
    }
}
