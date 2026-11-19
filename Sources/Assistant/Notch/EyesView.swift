import AppKit
import AssistantCore
import SwiftUI

struct EyesView: View {
    var phase: Phase
    var level: Double
    var anchor: CGPoint
    var lookingDown: Bool
    /// A fixed instant for offscreen snapshots; nil follows the clock.
    var frozenTime: Double?

    static let eyeWidth: CGFloat = 13
    static let eyeHeight: CGFloat = 24
    static let spacing: CGFloat = 15
    /// How long the eyes take to move from one phase's pose to the next.
    static let settle: Double = 0.32

    @State private var previous: Phase = .asleep
    @State private var changedAt: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !phase.isAwake || frozenTime != nil)) { context in
            let time = frozenTime ?? context.date.timeIntervalSinceReferenceDate
            let pose = pose(at: time)
            HStack(spacing: Self.spacing) {
                eye(pose)
                eye(pose)
            }
            .frame(height: Self.eyeHeight * 1.45)
            .offset(x: pose.dx, y: pose.dy)
        }
        .scaleEffect(x: phase.isAwake ? 1 : 0.6, y: phase.isAwake ? 1 : 0.05)
        .opacity(phase.isAwake ? 1 : 0)
        .animation(.spring(response: 0.36, dampingFraction: 0.6), value: phase.isAwake)
        .onChange(of: phase) { old, _ in
            previous = old
            changedAt = Date.timeIntervalSinceReferenceDate
        }
    }

    private func pose(at time: Double) -> EyePose {
        let gaze = pointerGaze()
        func resting(_ phase: Phase) -> EyePose {
            EyePose.resting(time: time, phase: phase, level: level, gazeX: gaze.x, gazeY: gaze.y, lookingDown: lookingDown)
        }
        guard frozenTime == nil, previous.isAwake else { return resting(phase).blinking(at: time) }
        let progress = (time - changedAt) / Self.settle
        return EyePose.blend(resting(previous), resting(phase), progress: progress).blinking(at: time)
    }

    private func eye(_ pose: EyePose) -> some View {
        let width = Self.eyeWidth * pose.squash
        let height = max(2.5, Self.eyeHeight * pose.openness)
        return RoundedRectangle(cornerRadius: min(width, height) / 2, style: .continuous)
            .fill(LinearGradient(colors: [Color.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: height)
            // A tight bright edge and a wide soft halo, so they read as lit
            // from inside against the black of the island.
            .shadow(color: Color.white.opacity(pose.glow * 0.9), radius: 2.5)
            .shadow(color: Color.white.opacity(pose.glow * 0.55), radius: 9)
    }

    private func pointerGaze() -> (x: Double, y: Double) {
        guard frozenTime == nil else { return (0, 0) }
        let pointer = NSEvent.mouseLocation
        let x = (pointer.x - anchor.x) / 500
        let y = (anchor.y - pointer.y) / 400
        return (min(max(x, -1), 1), min(max(y, 0), 1))
    }
}
