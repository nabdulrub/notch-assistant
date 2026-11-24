import Foundation
import Testing
@testable import AssistantCore

@Suite("When an update may restart the app")
struct UpdateMomentTests {
    @Test("asleep with nothing open, voice mode restarts")
    func voiceAsleepIsQuiet() {
        #expect(UpdateMoment(mode: .voice, phase: .asleep).isQuiet)
    }

    @Test("voice mode never restarts in the middle of a conversation", arguments: [Phase.listening, .thinking, .speaking, .followUp])
    func voiceAwakeIsNotQuiet(phase: Phase) {
        #expect(!UpdateMoment(mode: .voice, phase: phase).isQuiet)
    }

    @Test("text mode's eyes are always open, so the closed chat is what counts")
    func textWithTheChatClosedIsQuiet() {
        #expect(UpdateMoment(mode: .text, phase: .followUp, chatOpen: false).isQuiet)
        #expect(!UpdateMoment(mode: .text, phase: .followUp, chatOpen: true).isQuiet)
    }

    @Test("nothing restarts under a permission request, an open window or a session at work",
          arguments: [AssistantSettings.Mode.voice, .text])
    func whatHoldsARestartBack(mode: AssistantSettings.Mode) {
        #expect(!UpdateMoment(mode: mode, approvalPending: true).isQuiet)
        #expect(!UpdateMoment(mode: mode, windowOpen: true).isQuiet)
        #expect(!UpdateMoment(mode: mode, sessionWorking: true).isQuiet)
        #expect(UpdateMoment(mode: mode).isQuiet)
    }
}

@Suite("The update feed")
struct AppcastTests {
    private let release = AppRelease(version: "0.2", build: "41",
                                     url: "https://github.com/nabdulrub/notch-assistant/releases/download/v0.2/NotchAssistant-0.2.dmg",
                                     signature: "c2lnbmF0dXJl+/==", length: 3186147,
                                     published: Date(timeIntervalSince1970: 1_795_000_000))

    @Test("it is well formed and carries what the updater compares and checks")
    func theFeedHoldsTheRelease() throws {
        let xml = Appcast.xml(appName: "Notch Assistant", release: release)
        let document = try XMLDocument(xmlString: xml)
        let item = try #require(try document.nodes(forXPath: "/rss/channel/item").first as? XMLElement)
        #expect(item.elements(forName: "sparkle:version").first?.stringValue == "41")
        #expect(item.elements(forName: "sparkle:shortVersionString").first?.stringValue == "0.2")
        #expect(item.elements(forName: "sparkle:minimumSystemVersion").first?.stringValue == "26.0")
        let enclosure = try #require(item.elements(forName: "enclosure").first)
        #expect(enclosure.attribute(forName: "url")?.stringValue == release.url)
        #expect(enclosure.attribute(forName: "length")?.stringValue == "3186147")
        #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == "c2lnbmF0dXJl+/==")
        #expect(try document.nodes(forXPath: "/rss/channel/item").count == 1)
    }

    @Test("the date is one a feed reader understands, whatever the Mac's own language")
    func theDateIsInTheFeedFormat() {
        #expect(Appcast.xml(appName: "Notch Assistant", release: release).contains("<pubDate>Wed, 18 Nov 2026 11:06:40 +0000</pubDate>"))
    }

    @Test("a name or address with markup in it cannot break the feed")
    func markupIsEscaped() throws {
        var odd = release
        odd.url = "https://example.com/a.dmg?x=1&y=\"2\""
        let xml = Appcast.xml(appName: "Notch <Assistant> & co", release: odd)
        let document = try XMLDocument(xmlString: xml)
        #expect(try document.nodes(forXPath: "/rss/channel/title").first?.stringValue == "Notch <Assistant> & co")
        let enclosure = try #require(try document.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement)
        #expect(enclosure.attribute(forName: "url")?.stringValue == odd.url)
    }

    @Test("what sign_update prints is read back as a signature and a length")
    func signUpdateOutputIsRead() throws {
        let read = try #require(Appcast.signature(fromSignUpdate: "sparkle:edSignature=\"7cLALFUH+w==\" length=\"1623481\"\n"))
        #expect(read.signature == "7cLALFUH+w==")
        #expect(read.length == 1623481)
    }

    @Test("anything else is not mistaken for a signature",
          arguments: ["", "error: no key", "sparkle:edSignature=\"\" length=\"12\"", "sparkle:edSignature=\"abc\"", "sparkle:edSignature=\"abc\" length=\"many\""])
    func nonsenseIsRefused(output: String) {
        #expect(Appcast.signature(fromSignUpdate: output) == nil)
    }
}
