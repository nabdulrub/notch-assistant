import AVFoundation
import AssistantCore
import SwiftUI

/// The first-run setup: the eyes stay put at the top while the question under
/// them changes.
struct SetupView: View {
    @ObservedObject var model: SetupModel
    /// A fixed instant for offscreen snapshots; nil follows the clock.
    var frozenTime: Double?

    static let size = CGSize(width: 540, height: 610)

    var body: some View {
        VStack(spacing: 0) {
            EyesView(phase: model.eyes, level: 0, anchor: model.anchor, lookingDown: false, frozenTime: frozenTime)
                .scaleEffect(2.3)
                .frame(height: 120)
                .padding(.top, 34)
            Group {
                switch model.step {
                case .name: nameStep
                case .voice: voiceStep
                case .microphone: microphoneStep
                case .session: sessionStep
                case .ready: readyStep
                }
            }
            .id(model.step)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 14)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.bottom, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background {
            ZStack {
                WindowGlass()
                Color.black.opacity(0.58)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.26), value: model.step)
        .animation(.easeInOut(duration: 0.2), value: model.engine)
    }

    // MARK: Steps

    private var nameStep: some View {
        page("What should I answer to?", "You wake me by saying this name out loud, so pick one that is easy to say.") {
            TextField("Jarvis", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .medium))
                .multilineTextAlignment(.center)
                .frame(width: 260, height: 48)
                .background(field)
                .onSubmit { model.next() }
        }
    }

    private var voiceStep: some View {
        page("How should we talk?", "Either way a voice model does the talking and hands the real work to Claude Code. You can switch later.") {
            HStack(alignment: .top, spacing: 12) {
                choice("live", title: "Live",
                       detail: "OpenAI's voice model, on your own OpenAI API key. The best listener and the best voice. OpenAI bills you for each minute we are connected, and I hang up when we go quiet.")
                choice("sophon", title: "On this Mac",
                       detail: "Sophon, a small open model that runs right here. No key, no account, and nothing you say leaves the Mac. Needs a 9 GB download and about 9 GB of memory while I am open. Experimental.")
            }
            if model.engine == "live" {
                keyField("Your OpenAI API key", saved: "Saved. Paste another key to replace it.", text: $model.openAIKey,
                         state: model.openAIState, good: "Key works. Kept in a file on this Mac that only you can read.") { Task { await model.checkKey() } }
                    .onChange(of: model.openAIKey) { model.keyEdited() }
                HStack(spacing: 10) {
                    Text("Voice")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                    Picker("Voice", selection: $model.liveVoice) {
                        ForEach(SetupModel.liveVoices, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Spacer()
                }
            } else if model.localModelInstalled {
                status("checkmark.circle", "Sophon is installed. It loads when I start and takes about ten seconds.")
            } else {
                Text("Sophon is not on this Mac yet. Paste the install command in a terminal, let it finish, and this page will notice.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button(model.copiedInstall ? "Copied" : "Copy the install command") { model.copyInstallCommand() }
                    .buttonStyle(QuietButton())
            }
        }
    }

    private var microphoneStep: some View {
        page("Can I use the microphone?", "I listen for my name on this Mac. Nothing leaves it until you say the name.") {
            switch model.microphone {
            case .authorized:
                status("checkmark.circle", "Microphone is allowed.")
            case .denied, .restricted:
                status("mic.slash", "Microphone access is off for this app. Turn it on in System Settings, then come back.")
                Button("Open System Settings") { model.openMicrophoneSettings() }
                    .buttonStyle(QuietButton())
            default:
                Button("Allow the microphone") { model.askForMicrophone() }
                    .buttonStyle(PrimaryButton())
            }
        }
    }

    private var sessionStep: some View {
        page("Connect me to Claude Code", "I am only the voice. A Claude Code session on your own subscription does the thinking and runs your agents.") {
            if model.sessionAttached {
                status("checkmark.circle", "Connected to a Claude Code session.")
            } else if model.claudeInstalled == false {
                status("exclamationmark.circle", "Claude Code is not on this Mac yet. Install it from claude.com/claude-code, sign in, then open Setup again from the eyes icon in the menu bar.")
            } else {
                HStack(spacing: 8) {
                    Text("Starts in \(model.workingDirectory)")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Change") { model.chooseFolder() }
                        .buttonStyle(QuietButton(compact: true))
                }
                .padding(.bottom, 8)
                if model.startingSession {
                    Text("Starting Claude Code in herdr")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .shimmer(true)
                } else {
                    HStack(spacing: 10) {
                        if model.herdrPath != nil {
                            Button("Start it in herdr") { model.startSession() }
                                .buttonStyle(PrimaryButton())
                        }
                        Button(model.copied ? "Copied" : "Copy the command") { model.copyCommand() }
                            .buttonStyle(QuietButton())
                    }
                }
                Text(model.sessionProblem
                    ?? "To do it by hand, paste the command in a terminal and press Return when Claude Code asks about the development channel.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(model.sessionProblem == nil ? 0.45 : 0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
    }

    private var readyStep: some View {
        page("Say \u{201C}\(model.cleanName)\u{201D}",
             "Then just talk. \(model.settings.talkKey.display) works too, and saying bye sends me back to sleep.") {
            if !model.sessionAttached {
                Text("I still need a Claude Code session before I can do anything. Setup is under the eyes icon in the menu bar when you want to connect one.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Pieces

    private func page<Content: View>(_ title: String, _ detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 14)
            content()
        }
    }

    private var field: some View { FieldBackground() }

    private func choice(_ engine: String, title: String, detail: String) -> some View {
        let selected = model.engine == engine
        return Button {
            model.engine = engine
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
            .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.11 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(selected ? 0.55 : 0.08), lineWidth: selected ? 1.5 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func keyField(_ placeholder: String, saved: String, text: Binding<String>, state: SetupModel.KeyState, good: String,
                          check: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SecureField(state == .saved ? saved : placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .onSubmit(check)
                switch state {
                case .checking:
                    ProgressView().controlSize(.small)
                case .good, .saved:
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                case .empty, .bad:
                    if !text.wrappedValue.isEmpty {
                        Button("Check", action: check).buttonStyle(QuietButton(compact: true))
                    }
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .frame(height: 44)
            .background(field)
            Group {
                switch state {
                case .bad(let problem): Text(problem).foregroundStyle(.white.opacity(0.85))
                case .good: Text(good).foregroundStyle(.white.opacity(0.5))
                case .checking: Text("Checking the key").foregroundStyle(.white.opacity(0.5)).shimmer(true)
                case .saved: Text("A key is already saved on this Mac.").foregroundStyle(.white.opacity(0.5))
                case .empty: Text(" ")
                }
            }
            .font(.system(size: 12))
            .padding(.leading, 4)
        }
        .padding(.top, 6)
    }

    private func status(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(field)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("Back") { model.back() }
                .buttonStyle(QuietButton())
                .opacity(model.step == .name ? 0 : 1)
                .disabled(model.step == .name)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(Color.white.opacity(0.7)).frame(width: geometry.size.width * model.progress)
                }
            }
            .frame(height: 3)
            Button(model.step == .ready ? "Start" : "Continue") { model.next() }
                .buttonStyle(PrimaryButton())
                .disabled(!model.canContinue)
                .keyboardShortcut(.defaultAction)
        }
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.black)
            .padding(.horizontal, 20)
            .frame(height: 36)
            .background(Capsule().fill(Color.white.opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.28)))
            .contentShape(Capsule())
    }
}

struct QuietButton: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, compact ? 12 : 18)
            .frame(height: compact ? 28 : 36)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.1)))
            .contentShape(Capsule())
    }
}

/// The blurred desktop behind the window.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
