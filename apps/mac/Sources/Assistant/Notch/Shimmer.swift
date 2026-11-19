import SwiftUI

/// A band of light that sweeps across text, for labels that mean something is
/// going on right now. It sweeps, rests a beat, and sweeps again.
struct Shimmer: ViewModifier {
    var active: Bool
    /// A fixed instant for offscreen snapshots; nil follows the clock.
    var frozenTime: Double?

    private static let sweep = 1.5
    private static let rest = 0.7
    /// The band's width as a share of the text's.
    private static let band = 0.5

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: frozenTime != nil)) { context in
                    let time = frozenTime ?? context.date.timeIntervalSinceReferenceDate
                    let cycle = time.truncatingRemainder(dividingBy: Self.sweep + Self.rest)
                    let progress = min(cycle / Self.sweep, 1)
                    // Eased, so the light gathers speed and settles instead of sliding at one pace.
                    let eased = progress * progress * (3 - 2 * progress)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0), location: 0),
                                .init(color: .white, location: 0.5),
                                .init(color: .white.opacity(0), location: 1),
                            ],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: width * Self.band)
                            .offset(x: -width * Self.band + eased * width * (1 + Self.band))
                    }
                }
                .mask { content }
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

extension View {
    func shimmer(_ active: Bool, frozenTime: Double? = nil) -> some View {
        modifier(Shimmer(active: active, frozenTime: frozenTime))
    }
}
