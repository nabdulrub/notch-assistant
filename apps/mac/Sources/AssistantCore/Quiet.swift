import Foundation

/// When an open line has gone quiet enough to close.
///
/// Only silence counts. The time the assistant spends talking does not, and
/// neither does the time the user does: someone telling it something long is
/// heard to the end.
public struct QuietRule: Equatable, Sendable {
    /// How long a silence closes the line.
    public var idle: TimeInterval
    /// Talk that the assistant has not answered keeps the line open this much
    /// longer at most, so a room that never stops talking does not hold it open.
    public static let longestTalk: TimeInterval = 90

    public init(idle: TimeInterval) {
        self.idle = idle
    }

    /// - Parameters:
    ///   - lastEngaged: when the assistant last spoke, was handed something, or took a request.
    ///   - lastUserSound: when the user was last heard. Pass `now` while they are talking.
    public func isOver(at now: Date, lastEngaged: Date, lastUserSound: Date) -> Bool {
        let unanswered = now.timeIntervalSince(lastEngaged)
        guard unanswered > idle else { return false }
        if unanswered > idle + QuietRule.longestTalk { return true }
        return now.timeIntervalSince(max(lastEngaged, lastUserSound)) > idle
    }
}

/// A request said in the same breath as the name is heard out. In a loud room
/// the sentence may never seem to end, so there is a point at which it is taken
/// as it stands.
public enum NameRequest {
    /// Past this, it is taken as soon as the words stop coming.
    public static let usual: TimeInterval = 12
    /// No new words for this long means they have finished.
    public static let pause: TimeInterval = 3
    /// However long they go on, it is taken by now.
    public static let longest: TimeInterval = 60

    public static func isTaken(at now: Date, nameHeardAt: Date, lastNewWords: Date) -> Bool {
        let heard = now.timeIntervalSince(nameHeardAt)
        if heard > longest { return true }
        return heard > usual && now.timeIntervalSince(lastNewWords) > pause
    }
}
