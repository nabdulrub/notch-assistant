#!/bin/sh
# The herdr side of Notch Assistant. herdr runs this with one word:
#   start    open the app
#   nudge    tell the running app to look at the agents now
#   tell     hand the selection, or the focused pane, to the assistant
#   session  focus the Claude Code session the assistant talks through
set -u

SUPPORT="$HOME/Library/Application Support/NotchAssistant"
SOCKET="$SUPPORT/bridge.sock"
HERDR="${HERDR_BIN_PATH:-herdr}"

# The app's own binary: where it was installed, or a build next to this plugin.
app_binary() {
  for app in "${NOTCH_ASSISTANT_APP:-}" "/Applications/Notch Assistant.app" "$HOME/Applications/Notch Assistant.app" \
             "${HERDR_PLUGIN_ROOT:-.}/../../apps/mac/build/Notch Assistant.app"; do
    if [ -n "$app" ] && [ -x "$app/Contents/MacOS/Assistant" ]; then
      printf '%s\n' "$app"
      return 0
    fi
  done
  return 1
}

# One value out of the JSON herdr hands over. Empty when it is not there.
context() {
  [ -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ] || return 0
  printf '%s' "$HERDR_PLUGIN_CONTEXT_JSON" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null || true
}

assistant_name() {
  name=$(/usr/bin/plutil -extract assistantName raw -o - "$SUPPORT/settings.json" 2>/dev/null) || name=""
  printf '%s\n' "${name:-Jarvis}"
}

case "${1:-}" in
  start)
    if app=$(app_binary); then
      /usr/bin/open -g "$app"
    else
      echo "Notch Assistant is not installed. Put it in /Applications, or set NOTCH_ASSISTANT_APP." >&2
      exit 1
    fi
    ;;

  nudge)
    # Not running means nothing to tell, which is fine.
    [ -S "$SOCKET" ] || exit 0
    printf '{"type":"nudge"}\n' | /usr/bin/nc -U -w 1 "$SOCKET" >/dev/null 2>&1 || true
    ;;

  tell)
    app=$(app_binary) || { echo "Notch Assistant is not installed." >&2; exit 1; }
    selected=$(context selected_text)
    pane=${HERDR_PANE_ID:-$(context focused_pane_id)}
    tab=$(context tab_label)
    where="the herdr pane $pane"
    [ -n "$tab" ] && where="the herdr pane $pane, in the tab called $tab"
    if [ -n "$selected" ]; then
      text="Have a look at this, from $where: $selected"
    elif [ -n "$pane" ]; then
      text="Have a look at $where and tell me where it stands."
    else
      echo "There is no pane to hand over." >&2
      exit 1
    fi
    "$app/Contents/MacOS/Assistant" --say "$text"
    ;;

  session)
    name=$(assistant_name | tr '[:upper:]' '[:lower:]')
    "$HERDR" agent focus "$name" || { echo "There is no session called $name. Start it from the app's setup." >&2; exit 1; }
    ;;

  *)
    echo "usage: notch.sh start|nudge|tell|session" >&2
    exit 2
    ;;
esac
