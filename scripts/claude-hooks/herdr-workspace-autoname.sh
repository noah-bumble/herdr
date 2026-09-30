#!/bin/sh
# Bumble Confidential. For Internal Use Only.
# Claude Code UserPromptSubmit hook for Herdr.
# On the first user turn of a conversation, it asks a small Claude model for a
# 1-3 word description of the prompt and renames the current Herdr workspace.
#
# Install: add to ~/.claude/settings.json under hooks.UserPromptSubmit:
#   {"type":"command","command":"sh ~/.claude/hooks/herdr-workspace-autoname.sh","timeout":5}
#
# Environment knobs:
#   HERDR_AUTONAME_MODEL   model id for the naming call (default: claude-haiku-4-5-20251001)
#   HERDR_AUTONAME_DISABLE set to 1 to turn the hook off

set -eu

# Never run inside the nested naming call, or outside a Herdr pane.
[ "${HERDR_AUTONAME_NESTED:-}" = "1" ] && exit 0
[ "${HERDR_AUTONAME_DISABLE:-}" = "1" ] && exit 0
[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_WORKSPACE_ID:-}" ] || exit 0
command -v herdr >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
command -v /usr/bin/python3 >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

state_dir="${TMPDIR:-/tmp}/herdr-autoname"
mkdir -p "$state_dir" 2>/dev/null || exit 0

# Decide whether this is the first turn. Prints the prompt on stdout when it is.
prompt="$(HERDR_INPUT="$input" HERDR_STATE_DIR="$state_dir" /usr/bin/python3 - <<'PY'
import json, os, sys

raw = os.environ.get("HERDR_INPUT", "")
try:
    data = json.loads(raw)
except Exception:
    sys.exit(0)

if data.get("hook_event_name") not in (None, "UserPromptSubmit"):
    sys.exit(0)
if data.get("agent_id"):
    sys.exit(0)

session_id = str(data.get("session_id") or "")
prompt = str(data.get("prompt") or "").strip()
if not session_id or not prompt:
    sys.exit(0)

marker = os.path.join(os.environ["HERDR_STATE_DIR"], session_id)
if os.path.exists(marker):
    sys.exit(0)

# A resumed conversation already has user turns in its transcript.
transcript = data.get("transcript_path")
user_turns = 0
if isinstance(transcript, str) and os.path.exists(transcript):
    try:
        with open(transcript, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get("type") != "user" or entry.get("isMeta"):
                    continue
                content = (entry.get("message") or {}).get("content")
                if isinstance(content, str):
                    user_turns += 1
                elif isinstance(content, list) and any(
                    isinstance(part, dict) and part.get("type") == "text" for part in content
                ):
                    user_turns += 1
    except Exception:
        pass

try:
    open(marker, "w").close()
except Exception:
    pass

if user_turns > 1:
    sys.exit(0)

sys.stdout.write(prompt[:2000])
PY
)"
[ -n "$prompt" ] || exit 0

model="${HERDR_AUTONAME_MODEL:-claude-haiku-4-5-20251001}"
workspace_id="$HERDR_WORKSPACE_ID"
log="$state_dir/autoname.log"

# Do the slow part in the background so the hook returns at once.
(
  label="$(printf '%s' "$prompt" | HERDR_AUTONAME_NESTED=1 claude -p \
    --model "$model" \
    --setting-sources "" \
    --no-session-persistence \
    'Summarize the following coding-agent request as a workspace name of 1 to 3 words. Use title case. Output only the name, with no punctuation, quotes, or explanation. The request follows on stdin.' \
    2>>"$log" | head -n 1 | tr -d '\r"'"'"'`' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]]\{2,\}/ /g')"
  case "$label" in
    ""|*[!A-Za-z0-9\ ._/-]*) exit 0 ;;
  esac
  words="$(printf '%s' "$label" | wc -w | tr -d ' ')"
  [ "$words" -ge 1 ] && [ "$words" -le 3 ] || exit 0
  herdr workspace rename "$workspace_id" "$label" >>"$log" 2>&1 || true
) </dev/null >/dev/null 2>&1 &

exit 0
