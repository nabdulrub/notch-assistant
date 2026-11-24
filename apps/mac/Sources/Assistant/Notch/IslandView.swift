import AssistantCore
import SwiftUI

/// The whole overlay: one black shape that starts as the hardware notch and
/// grows to hold the eyes, a line of text, or an approval.
struct IslandView: View {
    @ObservedObject var model: NotchModel
    var frozenTime: Double?

    var body: some View {
        if model.mode == .text {
            TextIslandView(model: model, frozenTime: frozenTime)
        } else {
            voice
        }
    }

    private var voice: some View {
        let content = model.content
        let size = model.size
        let shape = NotchShape(topRadius: size.topRadius, bottomRadius: size.bottomRadius)

        return VStack(spacing: 0) {
            Color.clear.frame(height: model.metrics.height)
            EyesView(phase: model.phase, level: model.level, anchor: model.anchor,
                     lookingDown: model.approval != nil, frozenTime: frozenTime)
                .frame(height: 46)
            if content == .caption {
                captionRow.transition(.opacity)
            }
            if content == .approval, let request = model.approval {
                ApprovalView(request: request) { allow in model.resolve(request, allow: allow) }
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, size.topRadius + 16)
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { model.dismiss() }
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: content)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var captionRow: some View {
        if let caption = model.caption, !caption.isEmpty, model.captionIsOwnVoice, let spoken = model.captionProgress {
            Text(SpokenCaption.attributed(caption, spoken: spoken))
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        } else if let caption = model.caption, !caption.isEmpty {
            // Labels for something in progress get the light; words to read do not.
            let inProgress = !model.captionIsOwnVoice && (model.phase == .thinking || model.captionIsStatus)
            Text(caption)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(model.captionIsOwnVoice ? 0.96 : inProgress ? 0.5 : 0.62))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shimmer(inProgress, frozenTime: frozenTime)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        } else if let fleet = model.fleet, !fleet.isEmpty {
            Text(fleet.line)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 10)
        }
    }
}

struct ApprovalView: View {
    var request: ApprovalRequest
    /// Whether to say how it can be answered. Text mode has one way, a click.
    var saysHow = true
    var decide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .lineLimit(2)
            Text(request.preview)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.82))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.09), in: .rect(cornerRadius: 10))
            HStack(spacing: 8) {
                if saysHow {
                    Text(request.clickOnly ? "Needs a click" : "Say yes or no")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.5))
                }
                Spacer(minLength: 0)
                Button("Deny") { decide(false) }
                    .buttonStyle(IslandButtonStyle(prominent: false))
                Button("Allow") { decide(true) }
                    .buttonStyle(IslandButtonStyle(prominent: true))
            }
        }
        .padding(.bottom, 14)
    }
}

struct IslandButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(prominent ? Color.white : Color.white.opacity(0.14), in: .capsule)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(.capsule)
    }
}

/// The caption that follows along with the voice: the stretch of the sentence
/// being said right now, with the words already spoken lit and the ones still
/// to come dimmed.
enum SpokenCaption {
    /// About two lines of the island.
    static let pageLength = 76

    /// The run of words on screen while word number `spoken` is being said.
    static func page(of words: [String], spoken: Int) -> Range<Int> {
        var pages: [Range<Int>] = []
        var start = 0
        var length = 0
        for (index, word) in words.enumerated() {
            if length + word.count + 1 > pageLength, index > start {
                pages.append(start..<index)
                start = index
                length = 0
            }
            length += word.count + 1
        }
        pages.append(start..<words.count)
        let current = min(max(spoken - 1, 0), max(words.count - 1, 0))
        return pages.first { $0.contains(current) } ?? pages[pages.count - 1]
    }

    static func attributed(_ text: String, spoken: Int) -> AttributedString {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return AttributedString(text) }
        let page = page(of: words, spoken: spoken)
        let cut = min(max(spoken, page.lowerBound), page.upperBound)
        var said = AttributedString(words[page.lowerBound..<cut].joined(separator: " "))
        said.foregroundColor = Color.white.opacity(0.96)
        var coming = AttributedString((cut > page.lowerBound && cut < page.upperBound ? " " : "") + words[cut..<page.upperBound].joined(separator: " "))
        coming.foregroundColor = Color.white.opacity(0.32)
        return said + coming
    }
}
