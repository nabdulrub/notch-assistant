import Foundation

/// The MCP side of the helper, as pure line-in, lines-out logic. Claude Code
/// speaks JSON-RPC to it over stdio; it answers, and turns tool calls and
/// permission prompts into messages for the app.
///
/// It is a channel server: besides ordinary tools it can push messages into the
/// running session and relay permission prompts out of it.
public struct ChannelServer: Sendable {
    /// Revisions this server will agree to. Claude Code does not register a
    /// channel that negotiates 2026-07-28, so anything newer is answered with the
    /// last revision in this list.
    public static let supportedProtocols = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    static let fallbackProtocol = "2025-06-18"

    public struct Output: Sendable {
        public var replies: [Data] = []
        public var toApp: [BridgeMessage] = []
    }

    public var assistantName: String
    /// What the session is given as the channel's own instructions.
    public var instructions: String

    public init(assistantName: String, instructions: String? = nil) {
        self.assistantName = assistantName
        self.instructions = instructions ?? Persona.instructions(name: assistantName)
    }

    // MARK: Claude Code -> helper

    public func handle(line: Data, appConnected: Bool) -> Output {
        var output = Output()
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let method = object["method"] as? String else {
            return output
        }
        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedProtocols.contains(asked) ? asked : Self.fallbackProtocol
            output.replies.append(result(id, [
                "protocolVersion": version,
                "capabilities": [
                    "experimental": ["claude/channel": [String: Any](), "claude/channel/permission": [String: Any]()],
                    "tools": [String: Any](),
                ],
                "serverInfo": ["name": Persona.channelName, "version": "0.1.0"],
                "instructions": instructions,
            ]))
        case "ping":
            output.replies.append(result(id, [:]))
        case "tools/list":
            output.replies.append(result(id, ["tools": Self.tools]))
        case "tools/call":
            callTool(id: id, params: params, appConnected: appConnected, into: &output)
        case "notifications/claude/channel/permission_request":
            if let requestId = params["request_id"] as? String {
                output.toApp.append(.permissionRequest(
                    id: requestId,
                    tool: params["tool_name"] as? String ?? "a tool",
                    summary: params["description"] as? String ?? "",
                    preview: params["input_preview"] as? String ?? ""))
            }
        default:
            // Notifications carry no id and get no answer.
            if id != nil {
                output.replies.append(error(id, code: -32601, message: "Method not found: \(method)"))
            }
        }
        return output
    }

    private func callTool(id: Any?, params: [String: Any], appConnected: Bool, into output: inout Output) {
        let name = params["name"] as? String ?? ""
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        switch name {
        case "speak":
            let text = (arguments["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                output.replies.append(toolResult(id, "Nothing to say: text was empty.", isError: true))
                return
            }
            guard appConnected else {
                output.replies.append(toolResult(id, "Not spoken: the \(assistantName) app is not running, so the user cannot hear you.", isError: true))
                return
            }
            let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
            if words > ChannelServer.wordLimit {
                output.replies.append(toolResult(id, "Not said: that is \(words) words, which sounds like reading out a report. Say only the one thing that matters, in under \(ChannelServer.wordLimit) words, the way you would tell a friend. Drop the rest; they will ask if they want it. Do not split it across several speak calls.", isError: true))
                return
            }
            output.toApp.append(.speak(text, expectReply: arguments["expect_reply"] as? Bool ?? false))
            output.replies.append(toolResult(id, "Said out loud; the user heard it. If that was your answer, end the turn now: no more text, no more tool calls, no waiting. Whatever they say next arrives as a new message. If it was only a quick acknowledgement, carry on with the work."))
        case "show":
            guard appConnected else {
                output.replies.append(toolResult(id, "Not shown: the \(assistantName) app is not running.", isError: true))
                return
            }
            output.toApp.append(.show(title: arguments["title"] as? String ?? "",
                                      detail: arguments["detail"] as? String ?? ""))
            output.replies.append(toolResult(id, "Shown."))
        default:
            output.replies.append(error(id, code: -32602, message: "Unknown tool: \(name)"))
        }
    }

    /// A reply longer than this is a report, not talk.
    public static let wordLimit = 36

    static let tools: [[String: Any]] = [
        [
            "name": "speak",
            "_meta": ["anthropic/alwaysLoad": true],
            "description": "Say something out loud to the user. This is the only way the user hears you. Talk like a friend across the desk, not an assistant: casual, contractions, a filler here and there. Give the one thing that matters and stop, so they can ask for more. At most \(ChannelServer.wordLimit) words, always: there is no way around the limit. If there is more to tell, say the headline and offer the rest. No markdown, lists, code or emoji. Returns as soon as speech starts.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "text": ["type": "string", "description": "What to say, written the way it should be spoken."],
                    "expect_reply": ["type": "boolean", "description": "True when you asked the user a question and are waiting for the answer."],
                ],
                "required": ["text"],
            ],
        ],
        [
            "name": "show",
            "_meta": ["anthropic/alwaysLoad": true],
            "description": "Put a short silent note in the notch without speaking. For things worth a glance that are not worth interrupting the user for.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "A few words."],
                    "detail": ["type": "string", "description": "One short line of detail."],
                ],
                "required": ["title"],
            ],
        ],
    ]

    // MARK: app -> Claude Code

    /// The JSON-RPC notification for a message from the app, or nil when the
    /// message is not one the session should see.
    public func notification(for message: BridgeMessage) -> Data? {
        switch message.type {
        case .utterance:
            guard let text = message.text, !text.isEmpty else { return nil }
            return notify("notifications/claude/channel", [
                "content": text,
                "meta": ["kind": "speech", "via": Self.identifier(message.kind ?? "voice")],
            ])
        case .event:
            var meta: [String: String] = ["kind": Self.identifier(message.kind ?? "event")]
            for (key, value) in message.meta ?? [:] where key != "kind" {
                // Claude Code silently drops meta keys that are not identifiers.
                meta[Self.identifier(key)] = value
            }
            return notify("notifications/claude/channel", ["content": message.text ?? "", "meta": meta])
        case .permissionVerdict:
            guard let requestId = message.requestId, let allow = message.allow else { return nil }
            return notify("notifications/claude/channel/permission", [
                "request_id": requestId,
                "behavior": allow ? "allow" : "deny",
            ])
        case .hello, .speak, .show, .permissionRequest, .nudge:
            return nil
        }
    }

    static func identifier(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { scalar -> Character in
            let isWord = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar))) || scalar == "_"
            return isWord ? Character(scalar) : "_"
        }
        return cleaned.isEmpty ? "_" : String(cleaned)
    }

    // MARK: JSON-RPC

    private func result(_ id: Any?, _ value: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": value])
    }

    private func toolResult(_ id: Any?, _ text: String, isError: Bool = false) -> Data {
        result(id, ["content": [["type": "text", "text": text]], "isError": isError])
    }

    private func error(_ id: Any?, code: Int, message: String) -> Data {
        encode(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private func notify(_ method: String, _ params: [String: Any]) -> Data {
        encode(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data("{}".utf8)
    }
}
