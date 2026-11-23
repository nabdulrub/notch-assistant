import AssistantCore
import SwiftUI

/// The island in text mode. Closed, it is the notch with a tab to its right:
/// an icon and a count for each kind of agent. Open, it is the list of agents,
/// the typed conversation and the message box.
struct TextIslandView: View {
    @ObservedObject var model: NotchModel
    var frozenTime: Double?
    @FocusState private var typing: Bool

    /// No bounce. Closed, the island sits beside the hardware notch instead of
    /// behind it, so a spring that overshoots on the way back would draw it
    /// smaller than the notch for a moment and show the two as separate pieces.
    private static let spring = Animation.spring(response: 0.4, dampingFraction: 1)

    var body: some View {
        let content = model.textContent
        let size = model.size
        let shape = NotchShape(topRadius: size.topRadius, bottomRadius: size.bottomRadius)
        let inset = size.topRadius + 14

        VStack(spacing: 0) {
            if content != .bare { bar(content, size) }
            if content == .update, let update = model.update {
                UpdateLine(update: update)
                    .padding(.horizontal, inset)
                    .transition(.opacity)
            }
            if content == .open {
                AgentList(model: model, frozenTime: frozenTime)
                    .padding(.horizontal, size.topRadius + 6)
                    .transition(.opacity)
            }
            if content == .open || content == .approval, let request = model.approval {
                ApprovalView(request: request, saysHow: false) { allow in model.resolve(request, allow: allow) }
                    .padding(.horizontal, inset)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
            if content == .open {
                Thread(model: model, frozenTime: frozenTime)
                    .padding(.horizontal, inset)
                    .transition(.opacity)
                composer
                    .padding(.horizontal, size.topRadius + 8)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, alignment: .top)
        .frame(minHeight: size.height, alignment: .top)
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .contentShape(shape)
        .onTapGesture { if content == .tab || content == .update { model.open() } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.laidOutHeight = $0 }
        .offset(x: size.shift)
        .environment(\.colorScheme, .dark)
        .animation(Self.spring, value: content)
        .animation(Self.spring, value: size)
        .animation(Self.spring, value: model.roster)
        .animation(Self.spring, value: model.showsIdle)
        .animation(Self.spring, value: model.chat)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.isOpen) { _, open in typing = open }
    }

    // MARK: The row the notch sits in

    /// Eyes to the left of the notch, counts to the right. Closed, there is no
    /// left side: the tab hangs off the notch's right edge.
    private func bar(_ content: TextContent, _ size: IslandSize) -> some View {
        let notch = model.metrics.hasHardwareNotch ? model.metrics.width : 0
        let left = content == .tab ? 0 : (size.width - notch) / 2
        let right = size.width - notch - left
        let edge = size.topRadius + 16
        let fitsLabel = TextLayout.countsWidth(kinds: model.roster.kinds, needsYou: model.roster.needsYou) <= right - edge - 8

        return HStack(spacing: 0) {
            HStack(spacing: 0) {
                if content != .tab {
                    EyesView(phase: model.phase, level: 0, anchor: model.anchor, lookingDown: model.approval != nil,
                             frozenTime: frozenTime)
                        .scaleEffect(0.54)
                        .frame(width: 26, height: 18)
                        .padding(.leading, edge)
                }
                Spacer(minLength: 0)
            }
            .frame(width: left)
            Color.clear.frame(width: notch)
            HStack(spacing: 0) {
                if content != .tab { Spacer(minLength: 0) }
                Button { model.toggle() } label: {
                    KindCounts(roster: model.roster, showsLabel: content == .tab || fitsLabel, frozenTime: frozenTime)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.leading, content == .tab ? 12 : 0)
                .padding(.trailing, content == .tab ? 0 : edge)
                if content == .tab { Spacer(minLength: 0) }
            }
            .frame(width: right)
        }
        .frame(height: TextLayout.barHeight(metrics: model.metrics))
    }

    // MARK: The message box

    private var composer: some View {
        let ready = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 8) {
            if let row = model.targetRow {
                HStack(spacing: 5) {
                    AgentMarkView(kind: row.kind, lit: true, size: 12)
                    Text(row.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.96))
                        .lineLimit(1)
                        .frame(maxWidth: 130, alignment: .leading)
                        .fixedSize()
                    Button { model.target = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .frame(width: 14, height: 14)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .frame(height: 26)
                .background(Color.white.opacity(0.14), in: .capsule)
                .transition(.opacity)
            }
            TextField("Message", text: $model.draft, prompt: Text("Message").foregroundStyle(Color.white.opacity(0.32)))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.96))
                .tint(.white)
                .focused($typing)
                .onSubmit { model.send() }
            Button { model.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(ready ? Color.black : Color.white.opacity(0.5))
                    .frame(width: 26, height: 26)
                    .background(ready ? Color.white : Color.white.opacity(0.14), in: .circle)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .disabled(!ready)
        }
        .padding(.leading, model.targetRow == nil ? 14 : 7)
        .padding(.trailing, 7)
        .frame(height: 40)
        .background(Color.white.opacity(0.09), in: .capsule)
        .animation(Self.spring, value: model.target)
        .onAppear { DispatchQueue.main.async { typing = model.isOpen } }
    }
}

/// An icon for each kind of agent, and beside it how many of that kind are at
/// work right now: lit, with a light passing over the number. A kind with
/// nothing running is its icon alone, dimmed. When someone is waiting on the
/// user, that is said in words.
struct KindCounts: View {
    var roster: FleetRoster
    var showsLabel: Bool
    var frozenTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 12) {
                ForEach(roster.kinds.prefix(TextLayout.mostKinds), id: \.kind) { kind in
                    HStack(spacing: 5) {
                        AgentMarkView(kind: kind.kind, lit: kind.working > 0, size: 14)
                        if kind.working > 0 {
                            Text("\(kind.working)")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Color.white.opacity(0.96))
                                .shimmer(true, frozenTime: frozenTime)
                        }
                    }
                }
            }
            if showsLabel, roster.needsYou > 0 {
                Text(TextLayout.needsYouLabel(roster.needsYou))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(Color.white, in: .capsule)
            }
        }
        .fixedSize()
    }
}

/// What just happened, in a line or two under the closed notch.
private struct UpdateLine: View {
    var update: NotchUpdate

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                if let kind = update.kind {
                    AgentMarkView(kind: kind, lit: true, size: 13)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                }
                Text(update.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            if let detail = update.detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 13)
    }
}

/// Every agent that is doing something, one line each. A click on one aims the
/// message box at it.
private struct AgentList: View {
    @ObservedObject var model: NotchModel
    var frozenTime: Double?

    var body: some View {
        let roster = model.roster
        let rows = model.showsIdle ? roster.rows : roster.active
        VStack(alignment: .leading, spacing: 0) {
            if roster.isEmpty {
                Text("No agents running")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .frame(height: TextLayout.rowHeight)
            } else {
                CappedHeight(most: TextLayout.mostListHeight) {
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                Button { model.choose(row) } label: {
                                    AgentRowView(row: row, chosen: model.target == row.paneID, frozenTime: frozenTime)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
                if !model.showsIdle, roster.idle > 0 {
                    Button { model.showsIdle = true } label: {
                        Text(roster.idleLine)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.32))
                            .padding(.leading, 36)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 6)
    }
}

private struct AgentRowView: View {
    var row: AgentRow
    var chosen: Bool
    var frozenTime: Double?

    var body: some View {
        HStack(spacing: 10) {
            AgentMarkView(kind: row.kind, lit: row.isActive, size: 14)
                .frame(width: 16)
            Text(row.label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(row.isActive ? 0.96 : 0.62))
                .lineLimit(1)
                .layoutPriority(1)
            if let project = row.project, project != row.label {
                Text(project)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            status
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.horizontal, 10)
        .frame(height: TextLayout.rowHeight)
        .background(Color.white.opacity(chosen ? 0.09 : 0), in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }

    @ViewBuilder
    private var status: some View {
        switch row.status {
        case .blocked:
            Text("Needs you")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.white, in: .capsule)
        case .working:
            TimelineView(.periodic(from: .now, by: 20)) { context in
                let since = row.workingSince.map { Elapsed.short(context.date.timeIntervalSince($0)) } ?? ""
                Text(since.isEmpty ? "Working" : "Working \(since)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color.white.opacity(0.5))
                    .shimmer(true, frozenTime: frozenTime)
            }
        case .done:
            Text("Finished")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
        case .idle, .unknown:
            Text("Idle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.32))
        }
    }
}

/// The typed conversation: what the session says as plain lines, what the user
/// typed in a bubble on the right.
private struct Thread: View {
    @ObservedObject var model: NotchModel
    var frozenTime: Double?

    var body: some View {
        let messages = model.chat.messages
        if !messages.isEmpty || model.working != nil {
            CappedHeight(most: TextLayout.mostThreadHeight) {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(messages) { message in
                            if message.role == .you { mine(message) } else { theirs(message) }
                        }
                        if let working = model.working {
                            Text(working)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.5))
                                .lineLimit(1)
                                .shimmer(true, frozenTime: frozenTime)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.never)
                .defaultScrollAnchor(.bottom)
            }
            .padding(.top, 10)
        }
    }

    private func theirs(_ message: ChatMessage) -> some View {
        Text(message.text)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.96))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mine(_ message: ChatMessage) -> some View {
        HStack(spacing: 0) {
            Spacer(minLength: 56)
            VStack(alignment: .leading, spacing: 3) {
                if let to = message.to {
                    HStack(spacing: 4) {
                        AgentMarkView(kind: to.kind, lit: true, size: 10)
                        Text(to.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.62))
                            .lineLimit(1)
                    }
                }
                Text(message.text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.96))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.14), in: .rect(cornerRadius: 16))
        }
    }
}

/// As tall as what it holds, up to a limit; past that, what it holds scrolls.
private struct CappedHeight: Layout {
    var most: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = proposal.width ?? child.sizeThatFits(.unspecified).width
        let ideal = child.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: width, height: min(ideal.height, most))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
