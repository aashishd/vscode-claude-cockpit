#!/usr/bin/env bash
# Claude Cockpit hook helper.
#   $1 = state emoji (🟡 / 🔴 / 🟢)
#   $2 = event kind: init | processing | blocked | done
# stdin: Claude Code hook JSON.
# stdout: {"terminalSequence": "..."} that sets the terminal tab title to
#         "<emoji> ✳ <topic>", where <topic> is Claude's auto-generated
#         session title (read from the transcript's ai-title records).
# Side effect: blocked/done events are appended to
#         ~/.claude/vscode-bridge/events.jsonl for the VS Code extension.
set -u
emoji="${1:-}"
kind="${2:-}"
input="$(cat 2>/dev/null || true)"

if command -v python3 >/dev/null 2>&1; then
  # Hook JSON is passed via env var: the heredoc below occupies stdin for the
  # program text, so piped input would never reach the script.
  COCKPIT_HOOK_INPUT="$input" python3 - "$emoji" "$kind" <<'PY'
import json, os, sys, time

emoji = sys.argv[1]
kind = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    data = json.loads(os.environ.get("COCKPIT_HOOK_INPUT") or "{}")
except Exception:
    data = {}

title = ""
transcript = data.get("transcript_path") or ""
if transcript and os.path.isfile(transcript):
    last = None
    try:
        with open(transcript, "rb") as f:
            for line in f:
                if b'"ai-title"' in line:
                    last = line
        if last is not None:
            title = json.loads(last).get("aiTitle") or ""
    except Exception:
        pass
if not title:
    cwd = data.get("cwd") or ""
    title = os.path.basename(cwd) if cwd else "claude"

# ensure_ascii=False: emoji must be raw UTF-8. Surrogate-pair escapes
# (\ud83d...) get mangled into C1 control bytes that abort the OSC
# sequence in the terminal, killing the title entirely.
seq = "\033]0;%s ✳ %s\007" % (emoji, title)
sys.stdout.write(json.dumps({"terminalSequence": seq}, ensure_ascii=False))

if kind in ("blocked", "done"):
    try:
        bridge = os.path.join(os.path.expanduser("~"), ".claude", "vscode-bridge")
        os.makedirs(bridge, exist_ok=True)
        with open(os.path.join(bridge, "events.jsonl"), "a") as f:
            f.write(json.dumps({
                "state": kind,
                "cwd": data.get("cwd") or "",
                "title": title,
                "ts": int(time.time()),
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass
PY
elif command -v jq >/dev/null 2>&1; then
  tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
  title=""
  if [ -n "$tp" ] && [ -f "$tp" ]; then
    title="$(grep '"ai-title"' "$tp" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)"
  fi
  [ -z "$title" ] && title="$(basename "${cwd:-claude}")"
  seq="$(printf '\033]0;%s ✳ %s\007' "$emoji" "$title")"
  printf '%s' "$seq" | jq -Rsc '{terminalSequence: .}'
  if [ "$kind" = "blocked" ] || [ "$kind" = "done" ]; then
    bridge="$HOME/.claude/vscode-bridge"
    mkdir -p "$bridge" 2>/dev/null || true
    jq -nc --arg s "$kind" --arg c "$cwd" --arg t "$title" --argjson ts "$(date +%s)" \
      '{state:$s, cwd:$c, title:$t, ts:$ts}' >> "$bridge/events.jsonl" 2>/dev/null || true
  fi
else
  # No python3/jq: static title, no notification events. The %s arguments are
  # passed literally (not format-expanded), keeping the JSON escapes intact.
  printf '{"terminalSequence":"%s]0;%s ✳ claude%s"}' '\u001b' "$emoji" '\u0007'
fi
