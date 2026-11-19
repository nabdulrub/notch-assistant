import AssistantCore
import SwiftUI

/// Everything that can be changed after setup, one section at a time. The same
/// glass and the same eyes as setup, so it reads as the same app.
struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    /// A fixed instant for offscreen snapshots; nil follows the clock.
    var frozenTime: Double?

    static let size = CGSize(width: 800, height: 660)
    private static let sidebar: CGFloat = 196

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                ScrollView {
                    Group {
                        switch model.section {
                        case .general: general
                        case .voice: voice
                        case .delegation: delegation
                        case .persona: persona
                        case .instructions: instructions
                        }
                    }
                    .id(model.section)
                    .transition(.opacity)
                    .padding(.horizontal, 32)
                    .padding(.top, 44)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.never)
                // A long section runs out under the buttons, and fades there.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94),
                                             .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
                footer
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                WindowGlass()
                Color.black.opacity(0.58)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.2), value: model.section)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            EyesView(phase: .followUp, level: 0, anchor: model.anchor, lookingDown: false, frozenTime: frozenTime)
                .scaleEffect(1.5)
                .frame(maxWidth: .infinity)
                .frame(height: 64)
                .padding(.top, 52)
                .padding(.bottom, 26)
            ForEach(SettingsModel.Section.allCases) { section in
                let selected = model.section == section
                Button {
                    model.section = section
                } label: {
                    Text(section.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(selected ? 0.96 : 0.58))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.1 : 0)))
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.sidebar)
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.22))
    }

    // MARK: Sections

    private var general: some View {
        page("General", "What it answers to, how you call it, and where it works.") {
            card {
                row("Name", "You wake it by saying this out loud.") {
                    TextField("Jarvis", text: $model.draft.assistantName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                        .padding(.horizontal, 12)
                        .frame(width: 190, height: 36)
                        .background(FieldBackground())
                }
                row("Talk key", "Stands in for saying the name. Press it again to send it back to sleep.") {
                    Button(model.recordingKey ? "Press a shortcut" : model.draft.talkKey.display) { model.recordKey() }
                        .buttonStyle(QuietButton())
                }
                row("Session folder", "Claude Code starts in \(model.draft.workingDirectory).") {
                    Button("Change") { model.chooseFolder() }
                        .buttonStyle(QuietButton())
                }
            }
        }
    }

    private var voice: some View {
        page("Voice", "A voice model does the listening and the talking, and hands the real work to Claude Code.") {
            card {
                row("Voice model", model.draft.voiceEngine == "sophon"
                    ? "On this Mac. Switching, and your OpenAI key, are in Setup."
                    : "Live, on your own OpenAI key. Switching, and the key, are in Setup.") {
                    Button("Open Setup") { model.onOpenSetup?() }
                        .buttonStyle(QuietButton())
                }
                if model.draft.voiceEngine == "live" {
                    row("Voice", "How the live voice sounds.") {
                        Picker("Voice", selection: $model.draft.liveVoice) {
                            ForEach(SetupModel.liveVoices, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                if model.draft.voiceEngine == "sophon" {
                    row("Only my voice", "It learns the voice that says its name and takes anyone else, a television or a noise for the room. Needs the speaker model next to the voice model.") {
                        Toggle("Only my voice", isOn: $model.draft.onlyMyVoice)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(.white.opacity(0.5))
                    }
                }
                row("Goes back to sleep after", "How long it waits in silence before it stops listening.") {
                    seconds($model.draft.liveIdle, [10, 15, 20, 30, 60], off: nil)
                }
                row("Spoken updates", "How often it says where things are while agents are working.") {
                    seconds($model.draft.updateEvery, [20, 40, 60, 120, 300], off: "Off")
                }
            }
        }
    }

    private var delegation: some View {
        page("Delegation", "How the work gets handed out. A session that is running hears about a change right away.") {
            Text("What it does itself")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.bottom, -6)
            HStack(alignment: .top, spacing: 10) {
                style(.always, "Nothing", "It only talks. Every job goes to a worker, even a one-line check.")
                style(.quickLooks, "Quick looks", "It takes a short look itself, reading only. Anything longer goes to a worker.")
                style(.handsOn, "Small jobs", "It does lookups and one-file edits itself and hands over the bigger work.")
            }
            card {
                row("Its own model", "The Claude model the session runs on, from the next time it starts.") {
                    ModelField(model: $model.draft.model, inherit: nil)
                }
                row("Workers, real work", "Implementing, debugging, investigating, reviewing.") {
                    ModelField(model: $model.draft.delegation.workerModel, inherit: "My instructions decide")
                }
                row("Workers, small jobs", "Lookups, sweeps, running a suite.") {
                    ModelField(model: $model.draft.delegation.lightWorkerModel, inherit: "My instructions decide")
                }
                row("Where workers run", "herdr shows each one in a pane of its own.") {
                    Picker("Where workers run", selection: $model.draft.delegation.runner) {
                        Text("herdr when it can").tag(Delegation.Runner.auto)
                        Text("Always herdr").tag(Delegation.Runner.herdr)
                        Text("Background subagents").tag(Delegation.Runner.subagents)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                row("Workers at once", "Anything beyond that waits its turn.") {
                    Stepper(value: $model.draft.delegation.maxWorkers, in: 1...Delegation.mostWorkers) {
                        Text("\(model.draft.delegation.maxWorkers)")
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                    }
                    .fixedSize()
                }
                row("Talk it through first", "Before it plans, builds or changes something, it asks what it needs to know. Off, it starts at once and tells you what it assumed.") {
                    Toggle("Talk it through first", isOn: $model.draft.delegation.talksItThrough)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.white.opacity(0.5))
                }
                row("Ask before touching other agents", "The ones it did not start. Off, it sends them input and tells you after.") {
                    Toggle("Ask before touching other agents", isOn: $model.draft.delegation.askBeforeTouchingOthers)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(.white.opacity(0.5))
                }
            }
        }
    }

    private var persona: some View {
        page("Persona", "Who it is and how it sounds, in your own words. Left empty, it is the one it ships with: a dry, funny buddy.") {
            editor($model.draft.personality, "You are calm and precise, a little formal, and you never joke about prod.", height: 300)
            HStack(spacing: 10) {
                Button("Start from the default") { model.startFromDefault() }
                    .buttonStyle(QuietButton())
                if !model.draft.personality.isEmpty {
                    Button("Clear") { model.draft.personality = "" }
                        .buttonStyle(QuietButton())
                }
            }
            remark("Whatever you write, it keeps replies short and never reads out code or paths, since you hear it and do not read it.")
        }
    }

    private var instructions: some View {
        page("Instructions", "Your own rules, added after everything else it is told. Where the two clash, yours win.") {
            editor($model.draft.customInstructions, "Open every pull request as a draft. Never touch the main checkout. Check CI before you tell me something is done.",
                   height: 300)
            Button(model.copiedPrompt ? "Copied" : "Copy the full prompt") { model.copyPrompt() }
                .buttonStyle(QuietButton())
            remark("The full prompt is everything the session is told with these settings. One thing no rule changes: it always answers out loud.")
        }
    }

    // MARK: Pieces

    private func page<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 6)
            content()
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) { content() }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.08))))
    }

    private func row<Control: View>(_ title: String, _ detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            control()
        }
    }

    private func style(_ value: Delegation.Style, _ title: String, _ detail: String) -> some View {
        let selected = model.draft.delegation.style == value
        return Button {
            model.draft.delegation.style = value
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.11 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.55 : 0.08), lineWidth: selected ? 1.5 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// A choice of durations. A value from a hand-edited file that is not one of
    /// them is offered too, so opening the window never changes it.
    private func seconds(_ value: Binding<Double>, _ choices: [Double], off: String?) -> some View {
        let all = ((off == nil ? [] : [0]) + choices + [value.wrappedValue]).reduce(into: [Double]()) { list, next in
            if !list.contains(next) { list.append(next) }
        }.sorted()
        return Picker("Seconds", selection: value) {
            ForEach(all, id: \.self) { choice in
                Text(Self.duration(choice, off: off)).tag(choice)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }

    static func duration(_ seconds: Double, off: String?) -> String {
        if seconds <= 0, let off { return off }
        if seconds >= 60, seconds.truncatingRemainder(dividingBy: 60) == 0 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(Int(seconds)) seconds"
    }

    private func editor(_ text: Binding<String>, _ example: String, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 9)
                .padding(.vertical, 12)
            if text.wrappedValue.isEmpty {
                Text(example)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(FieldBackground())
    }

    private func remark(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(model.note ?? " ")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.62))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if model.hasChanges {
                Button("Revert") { model.revert() }
                    .buttonStyle(QuietButton())
            }
            Button("Save") { model.save() }
                .buttonStyle(PrimaryButton())
                .disabled(!model.hasChanges)
                .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 32)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }
}

/// A Claude model, by its short name or by any id typed in.
struct ModelField: View {
    @Binding var model: String
    /// What the empty choice is called, where leaving it open is allowed.
    var inherit: String?

    static let names = ["sonnet", "opus", "haiku", "fable"]
    private static let other = "\u{0}other"

    @State private var typing = false

    private var isListed: Bool { Self.names.contains(model) || (model.isEmpty && inherit != nil) }

    var body: some View {
        HStack(spacing: 8) {
            if typing || !isListed {
                TextField("claude-sonnet-5-5", text: $model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(width: 150, height: 30)
                    .background(FieldBackground())
            }
            Picker("Model", selection: Binding(
                get: { typing || !isListed ? Self.other : model },
                set: { choice in
                    typing = choice == Self.other
                    if !typing { model = choice } else if isListed { model = "" }
                })) {
                if let inherit { Text(inherit).tag("") }
                ForEach(Self.names, id: \.self) { Text($0.capitalized).tag($0) }
                Text("Another model").tag(Self.other)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

/// The filled, hairlined shape behind every field.
struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}
