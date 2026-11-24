import Foundation

/// The hardware notch of the screen the island sits on, or a stand-in for a
/// screen that has none.
public struct NotchMetrics: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var hasHardwareNotch: Bool

    public init(width: Double, height: Double, hasHardwareNotch: Bool) {
        self.width = width
        self.height = height
        self.hasHardwareNotch = hasHardwareNotch
    }

    /// A screen without a notch gets a thin sliver at the top edge while asleep,
    /// so there is still one shape to grow from.
    public static let floating = NotchMetrics(width: 150, height: 5, hasHardwareNotch: false)
}

/// What the island is showing. One shape morphs between these; nothing else
/// appears beside it.
public enum IslandContent: Equatable, Sendable {
    case asleep
    case eyes
    case caption
    case approval
}

public struct IslandSize: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var topRadius: Double
    public var bottomRadius: Double
    /// How far its centre sits to the right of the notch's. Only the tab that
    /// text mode hangs off the notch's right edge is off centre.
    public var shift: Double = 0
}

public enum NotchLayout {
    public static let canvasWidth: Double = 840
    public static let canvasHeight: Double = 600

    static let eyesZone: Double = 46
    static let captionZone: Double = 44
    static let approvalZone: Double = 126
    static let wing: Double = 18

    public static func content(phase: Phase, caption: String?, approval: ApprovalRequest?, fleet: FleetSummary?) -> IslandContent {
        if approval != nil { return .approval }
        if !phase.isAwake {
            return .asleep
        }
        let hasText = !(caption ?? "").isEmpty || !(fleet?.isEmpty ?? true)
        return hasText ? .caption : .eyes
    }

    public static func size(metrics: NotchMetrics, content: IslandContent) -> IslandSize {
        switch content {
        case .asleep:
            return IslandSize(width: metrics.width, height: metrics.height,
                              topRadius: metrics.hasHardwareNotch ? 6 : 2,
                              bottomRadius: metrics.hasHardwareNotch ? 10 : 2.5)
        case .eyes:
            return IslandSize(width: max(metrics.width, 150) + wing * 2,
                              height: metrics.height + eyesZone,
                              topRadius: 8, bottomRadius: 22)
        case .caption:
            return IslandSize(width: max(metrics.width + wing * 2, 340),
                              height: metrics.height + eyesZone + captionZone,
                              topRadius: 8, bottomRadius: 26)
        case .approval:
            return IslandSize(width: max(metrics.width + wing * 2, 400),
                              height: metrics.height + eyesZone + approvalZone,
                              topRadius: 8, bottomRadius: 30)
        }
    }
}
