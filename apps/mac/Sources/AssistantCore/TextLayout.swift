import Foundation

/// What the island is showing in text mode. Nothing is said aloud here: the
/// notch carries the agents' statuses, and opens into a chat that is typed.
public enum TextContent: Equatable, Sendable {
    /// No agents and nothing to say: the notch alone.
    case bare
    /// Closed, with a tab to the right of the notch: an icon for each kind of
    /// agent and how many of them are at work.
    case tab
    /// Closed, with a line under the notch about something that just happened.
    case update
    /// Closed, with a yes or no the session is waiting on.
    case approval
    /// Open: the agents, the conversation and the message box.
    case open
}

public enum TextLayout {
    /// How many kinds of agent get an icon and a count of their own.
    public static let mostKinds = 3
    /// The list and the conversation scroll past these heights.
    public static let mostListHeight: Double = 204
    public static let mostThreadHeight: Double = 170
    public static let rowHeight: Double = 34

    public static func content(roster: FleetRoster, isOpen: Bool, hasUpdate: Bool, hasApproval: Bool) -> TextContent {
        if isOpen { return .open }
        if hasApproval { return .approval }
        if hasUpdate { return .update }
        return roster.isEmpty ? .bare : .tab
    }

    /// The row the notch sits in. A screen without a notch still needs room
    /// for the eyes and the counts.
    public static func barHeight(metrics: NotchMetrics) -> Double {
        metrics.hasHardwareNotch ? metrics.height : 32
    }

    public static func needsYouLabel(_ count: Int) -> String {
        count == 1 ? "1 needs you" : "\(count) need you"
    }

    /// Room for the icons and counts, and for the label when someone is waiting.
    public static func countsWidth(kinds: [KindCount], needsYou: Int) -> Double {
        let shown = kinds.prefix(mostKinds)
        guard !shown.isEmpty else { return 0 }
        var width = 0.0
        // The number is how many are at work; with none, the icon stands alone.
        for kind in shown { width += 15 + (kind.working > 0 ? 5 + Double(String(kind.working).count) * 8 : 0) }
        width += Double(shown.count - 1) * 12
        if needsYou > 0 { width += 10 + Double(needsYouLabel(needsYou).count) * 6.8 + 18 }
        return width
    }

    /// The part of the closed island that sticks out to the right of the notch.
    public static func tabWidth(kinds: [KindCount], needsYou: Int) -> Double {
        let counts = countsWidth(kinds: kinds, needsYou: needsYou)
        return counts == 0 ? 0 : 12 + counts + 18
    }

    /// The closed shapes are exactly this size. The open ones are this wide
    /// and at least this tall: what they hold decides the rest.
    public static func size(metrics: NotchMetrics, content: TextContent, roster: FleetRoster) -> IslandSize {
        let bar = barHeight(metrics: metrics)
        switch content {
        case .bare:
            return NotchLayout.size(metrics: metrics, content: .asleep)
        case .tab:
            let tab = tabWidth(kinds: roster.kinds, needsYou: roster.needsYou)
            guard metrics.hasHardwareNotch else {
                return IslandSize(width: tab + 12, height: bar, topRadius: 6, bottomRadius: 10)
            }
            return IslandSize(width: metrics.width + tab, height: bar, topRadius: 6, bottomRadius: 10, shift: tab / 2)
        case .update:
            return IslandSize(width: max(metrics.width + 220, 440), height: bar, topRadius: 8, bottomRadius: 26)
        case .approval:
            return IslandSize(width: max(metrics.width + 220, 440), height: bar, topRadius: 8, bottomRadius: 30)
        case .open:
            return IslandSize(width: max(metrics.width + 260, 480), height: bar, topRadius: 8, bottomRadius: 30)
        }
    }
}
