import Foundation

/// The questions first-run setup asks, in order.
public enum SetupStep: Int, CaseIterable, Sendable {
    case mode, name, voice, microphone, session, ready

    /// Text mode has no voice to choose and nothing to listen with, so it is
    /// never asked for a key, a model or the microphone.
    public static func steps(for mode: AssistantSettings.Mode) -> [SetupStep] {
        switch mode {
        case .voice: return allCases
        case .text: return allCases.filter { $0 != .voice && $0 != .microphone }
        }
    }

    public func next(in mode: AssistantSettings.Mode) -> SetupStep? {
        let steps = Self.steps(for: mode)
        guard let index = steps.firstIndex(of: self) else { return steps.first { $0.rawValue > rawValue } }
        return index + 1 < steps.count ? steps[index + 1] : nil
    }

    public func previous(in mode: AssistantSettings.Mode) -> SetupStep? {
        let steps = Self.steps(for: mode)
        guard let index = steps.firstIndex(of: self) else { return steps.last { $0.rawValue < rawValue } }
        return index > 0 ? steps[index - 1] : nil
    }

    /// How far along this step is, from just above zero to one.
    public func progress(in mode: AssistantSettings.Mode) -> Double {
        let steps = Self.steps(for: mode)
        let index = steps.firstIndex(of: self) ?? steps.count - 1
        return Double(index + 1) / Double(steps.count)
    }
}
