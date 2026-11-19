# Jarvis

A voice that lives in the Mac notch and runs your Claude Code agents. Say its
name, ask for something, and it hands the work to a Claude Code session on your
own subscription, then tells you what happened.

## What you need

- An Apple Silicon Mac on macOS 26 or later
- [Claude Code](https://claude.com/claude-code), installed and signed in
- An OpenAI API key that can use `gpt-live-1`, or no key at all if you pick
  "On this Mac" during setup
- Optional: [herdr](https://herdr.dev), so it can start and watch worker agents
  in their own panes. Without it, it uses Claude Code's background subagents.

## Install

Open the disk image and drag Jarvis onto Applications. Builds are not signed
with Apple yet, so the first time, open it from Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Jarvis.app && open /Applications/Jarvis.app
```

Setup starts by itself: a name, the voice and its key, the microphone, and the
Claude Code session. You can open it again from the eyes icon in the menu bar.

## Using it

- Say "Jarvis" and talk, or press Control-Option-Space.
- Say "bye" to send it back to sleep. It also hangs up by itself after 15
  seconds of quiet, because the live voice is billed while it is connected.
- Asleep, nothing leaves the Mac. The name is listened for on-device.

## Build from source

Needs Xcode 27 or the Swift 6.2 toolchain. There is no Xcode project.

```sh
make run     # build, bundle and launch
make setup   # launch with setup open
make dist    # a disk image in dist/ to give to someone else
make log     # the last lines of the log
make test
```

`scripts/dist.sh` signs and notarizes when `SIGN_IDENTITY` and
`NOTARY_PROFILE` are set; otherwise the image is signed ad hoc.

## Where things live

- `Sources/AssistantCore`: the logic with no UI, covered by the tests
- `Sources/Assistant`: the app (notch, microphone, voices, setup)
- `Sources/AssistantChannel`: the helper Claude Code runs to talk to the app
- `~/Library/Application Support/NotchAssistant`: settings, keys and the log
