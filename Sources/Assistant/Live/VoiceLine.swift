import Foundation

/// The voice model on the other end of the line. It listens, talks, and hands
/// over what it cannot answer itself. OpenAI's live model and the model that
/// runs on this Mac both fit.
@MainActor
protocol VoiceLine: AnyObject {
    var onStarted: (() -> Void)? { get set }
    /// Mono signed 16-bit little-endian samples at 24 kHz.
    var onAudio: ((Data) -> Void)? { get set }
    var onUserText: ((String) -> Void)? { get set }
    var onVoiceText: ((String) -> Void)? { get set }
    /// The voice model wants the session to deal with what was just said.
    var onHandOff: ((String) -> Void)? { get set }
    /// The user cut in: speech that has not been played yet is to be dropped.
    var onCutIn: (() -> Void)? { get set }
    /// The user sent it away.
    var onDismissed: (() -> Void)? { get set }
    /// Called once, however it ended. The flag is true when that was asked for.
    var onEnded: ((Bool) -> Void)? { get set }

    /// True when what it is given to say is said word for word, not retold.
    var speaksWordForWord: Bool { get }

    func open()
    func sendAudio(_ pcm: Data)
    /// Something for the voice to say.
    func say(_ text: String, handOff: String?)
    /// Something for the voice to know without saying it now.
    func remember(_ text: String, handOff: String?)
    func setMuted(_ muted: Bool)
    /// Stop talking now.
    func interrupt()
    func close()
}
