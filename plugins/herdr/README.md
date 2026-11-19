# Notch Assistant for herdr

The herdr side of [Notch Assistant](../../README.md). The app works without it.
With it:

- **It starts with herdr.** A startup hook opens the app. Only one copy ever runs.
- **It hears every change.** By itself the app looks at your agents once a second.
  The plugin tells it the moment an agent starts, finishes or gets stuck, so a
  turn shorter than a second is not missed.
- **You can hand it a pane.** One action sends the focused pane, or the text you
  selected in it, to the assistant: "have a look at this".

## Install

```sh
herdr plugin install nabdulrub/notch-assistant/plugins/herdr
```

You also need the app itself: [download it](https://github.com/nabdulrub/notch-assistant/releases/latest)
and drag it to Applications. Working on the plugin from a checkout? Link it
instead with `herdr plugin link /path/to/notch-assistant/plugins/herdr`.

The app is looked for in `/Applications`, then `~/Applications`, then a build
next to the plugin. Set `NOTCH_ASSISTANT_APP` to point somewhere else.

## Actions

| Action | What it does |
| --- | --- |
| `notch-assistant.open` | Starts the app if it is not running |
| `notch-assistant.tell` | Hands the selection, or the focused pane, to the assistant |
| `notch-assistant.session` | Focuses the Claude Code session the assistant talks through |

## A key for it

In your herdr config:

```toml
[[keys.command]]
key = "prefix+j"
type = "plugin_action"
command = "notch-assistant.tell"
description = "hand this pane to the assistant"
```

## What it runs

One shell script, `notch.sh`, and nothing else. It talks to the app over the
app's own socket in `~/Library/Application Support/NotchAssistant`, and to herdr
through the herdr command. It sends nothing anywhere else.
