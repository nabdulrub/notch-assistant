import Foundation

/// Whether a downloaded update may replace the running app right now.
/// Installing means quitting and starting again, so it waits for a moment
/// when nothing would be cut off.
public struct UpdateMoment: Equatable, Sendable {
    public var mode: AssistantSettings.Mode
    public var phase: Phase
    /// Text mode: the chat is open.
    public var chatOpen: Bool
    /// The session is in the middle of something it was asked to do.
    public var sessionWorking: Bool
    /// A permission request is waiting on the user.
    public var approvalPending: Bool
    /// Setup or Settings is open.
    public var windowOpen: Bool

    public init(mode: AssistantSettings.Mode = .voice, phase: Phase = .asleep, chatOpen: Bool = false,
                sessionWorking: Bool = false, approvalPending: Bool = false, windowOpen: Bool = false) {
        self.mode = mode
        self.phase = phase
        self.chatOpen = chatOpen
        self.sessionWorking = sessionWorking
        self.approvalPending = approvalPending
        self.windowOpen = windowOpen
    }

    public var isQuiet: Bool {
        if approvalPending || windowOpen || sessionWorking { return false }
        switch mode {
        // Awake, it is listening or talking.
        case .voice: return phase == .asleep
        // The eyes never shut in text mode; the chat being closed is what says nobody is typing.
        case .text: return !chatOpen
        }
    }
}

/// One version of the app, as the update feed describes it.
public struct AppRelease: Equatable, Sendable {
    /// What people call it: 0.2.
    public var version: String
    /// What versions are compared by: a number that only ever grows.
    public var build: String
    public var url: String
    /// The EdDSA signature of the file at `url`, in base64.
    public var signature: String
    /// The size of that file in bytes.
    public var length: Int
    public var minimumSystem: String
    public var published: Date

    public init(version: String, build: String, url: String, signature: String, length: Int,
                minimumSystem: String = "26.0", published: Date = Date()) {
        self.version = version
        self.build = build
        self.url = url
        self.signature = signature
        self.length = length
        self.minimumSystem = minimumSystem
        self.published = published
    }
}

/// The feed the app reads to learn there is a new version. It holds the
/// latest release only: every copy goes straight to it.
public enum Appcast {
    public static func xml(appName: String, release: AppRelease) -> String {
        let date = DateFormatter()
        date.locale = Locale(identifier: "en_US_POSIX")
        date.timeZone = TimeZone(secondsFromGMT: 0)
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
                <title>\(escape(appName))</title>
                <item>
                    <title>\(escape(release.version))</title>
                    <pubDate>\(date.string(from: release.published))</pubDate>
                    <sparkle:version>\(escape(release.build))</sparkle:version>
                    <sparkle:shortVersionString>\(escape(release.version))</sparkle:shortVersionString>
                    <sparkle:minimumSystemVersion>\(escape(release.minimumSystem))</sparkle:minimumSystemVersion>
                    <enclosure url="\(escape(release.url))" length="\(release.length)" type="application/octet-stream" sparkle:edSignature="\(escape(release.signature))"/>
                </item>
            </channel>
        </rss>

        """
    }

    /// What Sparkle's `sign_update` prints: `sparkle:edSignature="…" length="…"`.
    public static func signature(fromSignUpdate output: String) -> (signature: String, length: Int)? {
        guard let signature = attribute("sparkle:edSignature", in: output), !signature.isEmpty,
              let length = attribute("length", in: output).flatMap(Int.init) else { return nil }
        return (signature, length)
    }

    private static func attribute(_ name: String, in text: String) -> String? {
        guard let start = text.range(of: "\(name)=\"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
