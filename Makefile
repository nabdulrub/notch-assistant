APP_NAME ?= Jarvis
APP := build/$(APP_NAME).app
BIN := $(APP)/Contents/MacOS/Assistant

.PHONY: build test bundle dist demo run setup stop session log snapshot clean

build:
	swift build

test:
	swift test

bundle:
	APP_NAME="$(APP_NAME)" ./scripts/bundle.sh

# Loops every notch state so the look and motion can be judged with nothing else
# wired in. Stop it with `make stop` or from the eyes icon in the menu bar.
demo: bundle
	@pkill -x Assistant || true
	@open -n "$(APP)" --args --demo
	@echo "demo running, look at the notch"

# Launched through `open` so macOS asks for the microphone on behalf of the app,
# not the terminal it was started from.
run: bundle
	@pkill -x Assistant || true
	@open -n "$(APP)"
	@echo "running. log: ~/Library/Application Support/NotchAssistant/assistant.log"

# Opens the first-run setup again: name, voice and keys, microphone, session.
setup: bundle
	@pkill -x Assistant || true
	@open -n "$(APP)" --args --setup

# A disk image to give to someone else. See scripts/dist.sh for signing.
dist:
	APP_NAME="$(APP_NAME)" ./scripts/dist.sh

# The line that starts the orchestrator session. Run it in a terminal or a herdr pane.
session:
	@"$(BIN)" --session-command

log:
	@tail -n 40 "$(HOME)/Library/Application Support/NotchAssistant/assistant.log"

stop:
	@pkill -x Assistant || true

# One PNG per state, rendered offscreen, in build/snapshots.
snapshot:
	swift run Assistant --snapshot build/snapshots

clean:
	rm -rf .build build
