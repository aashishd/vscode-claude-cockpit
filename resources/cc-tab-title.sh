#!/usr/bin/env bash
# Claude Cockpit hook helper.
#   $1 = state emoji (🟡 / 🔴 / 🟢)
#   $2 = event kind: init | processing | blocked | done
# stdin: Claude Code hook JSON.
# stdout: {"terminalSequence": "..."} that sets the terminal tab title to
#         "<emoji> ✳ <topic>". <topic> resolution order:
#           1. session name in ~/.claude/sessions/<pid>.json (skipping names
#              merely derived from the directory),
#           2. newest custom-title (/rename) or ai-title transcript record,
#           3. the session's first user prompt, shortened,
#           4. the cwd basename.
#         Claude Code >= ~2.1.198 generates AI titles only on demand (no hook
#         carries them), hence the first-prompt fallback.
# Side effect: blocked/done events are appended to
#         ~/.claude/vscode-bridge/events.jsonl for the VS Code extension
#         (notifications + sounds). Events carry CLAUDE_COCKPIT_TERM_ID
#         (injected by the extension) so it can focus the exact terminal.
set -u
emoji="${1:-}"
kind="${2:-}"
input="$(cat 2>/dev/null || true)"

if command -v python3 >/dev/null 2>&1; then
  # Hook JSON is passed via env var: the heredoc below occupies stdin for the
  # program text, so piped input would never reach the script.
  COCKPIT_HOOK_INPUT="$input" python3 - "$emoji" "$kind" <<'PY'
import glob, json, os, sys, time

emoji = sys.argv[1]
kind = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    data = json.loads(os.environ.get("COCKPIT_HOOK_INPUT") or "{}")
except Exception:
    data = {}

home = os.path.expanduser("~")

def session_name(session_id):
    # Live session metadata (bg jobs get AI names, /rename lands here too).
    # nameSource "derived" means the name is just the directory name plus a
    # suffix, not a real topic: skip those.
    if not session_id:
        return ""
    best, best_ts = "", -1
    for f in glob.glob(os.path.join(home, ".claude", "sessions", "*.json")):
        try:
            with open(f) as fh:
                meta = json.load(fh)
        except Exception:
            continue
        if meta.get("sessionId") != session_id or meta.get("nameSource") == "derived":
            continue
        name = meta.get("name") or ""
        ts = meta.get("updatedAt") or 0
        if name and ts >= best_ts:
            best, best_ts = name, ts
    return best

def prompt_text(record):
    # Text of a user record; "" for meta/command/tool-result records.
    if record.get("isMeta"):
        return ""
    content = (record.get("message") or {}).get("content")
    text = ""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                text = block.get("text") or ""
                break
    text = text.strip()
    # Skip command wrappers (<command-name>...), interruptions ([Request
    # interrupted...]) and bare slash commands: they make poor topics.
    if not text or text[0] in "<[/":
        return ""
    return text

def shorten(text, limit=45):
    text = " ".join(text.split())
    if len(text) <= limit:
        return text
    cut = text[:limit]
    if " " in cut:
        cut = cut.rsplit(" ", 1)[0]
    return cut + "…"

def transcript_titles(transcript):
    # One pass: newest custom-title/ai-title records + first real user prompt.
    last_custom = last_ai = None
    first_prompt = ""
    if transcript and os.path.isfile(transcript):
        try:
            with open(transcript, "rb") as f:
                for line in f:
                    if b'"custom-title"' in line:
                        last_custom = line
                    elif b'"ai-title"' in line:
                        last_ai = line
                    elif not first_prompt and b'"type":"user"' in line:
                        try:
                            first_prompt = prompt_text(json.loads(line))
                        except Exception:
                            pass
        except Exception:
            pass
    title = ""
    for last, key in ((last_custom, "customTitle"), (last_ai, "aiTitle")):
        if last is not None and not title:
            try:
                title = json.loads(last).get(key) or ""
            except Exception:
                pass
    return title, shorten(first_prompt)

title = ""
try:
    title = session_name(data.get("session_id") or "")
except Exception:
    pass
if not title:
    try:
        title, first_prompt = transcript_titles(data.get("transcript_path") or "")
        if not title:
            title = first_prompt
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
        bridge = os.path.join(home, ".claude", "vscode-bridge")
        os.makedirs(bridge, exist_ok=True)
        with open(os.path.join(bridge, "events.jsonl"), "a") as f:
            f.write(json.dumps({
                "state": kind,
                "cwd": data.get("cwd") or "",
                "title": title,
                "term": os.environ.get("CLAUDE_COCKPIT_TERM_ID") or "",
                "ts": int(time.time()),
            }, ensure_ascii=False) + "\n")
    except Exception:
        pass
PY
elif command -v jq >/dev/null 2>&1; then
  tp="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
  sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
  title=""
  if [ -n "$sid" ]; then
    for f in "$HOME/.claude/sessions"/*.json; do
      [ -f "$f" ] || continue
      t="$(jq -r --arg sid "$sid" \
        'select(.sessionId == $sid and .nameSource != "derived") | .name // empty' \
        "$f" 2>/dev/null)"
      [ -n "$t" ] && title="$t"
    done
  fi
  if [ -z "$title" ] && [ -n "$tp" ] && [ -f "$tp" ]; then
    title="$(grep '"custom-title"' "$tp" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)"
    [ -z "$title" ] && title="$(grep '"ai-title"' "$tp" 2>/dev/null | tail -1 | jq -r '.aiTitle // empty' 2>/dev/null)"
    if [ -z "$title" ]; then
      # First real user prompt, shortened (skip meta/command/slash lines).
      title="$(grep -m 25 '"type":"user"' "$tp" 2>/dev/null \
        | jq -r 'select(.isMeta != true) | .message.content // ""
                 | if type == "string" then .
                   elif type == "array" then ([.[]? | select(type == "object" and .type == "text") | .text] | .[0] // "")
                   else "" end
                 | gsub("\\s+"; " ") | ltrimstr(" ")
                 | select(length > 0) | select(test("^[<\\[/]") | not)
                 | if length > 45 then .[0:45] + "…" else . end' 2>/dev/null \
        | head -1)"
    fi
  fi
  [ -z "$title" ] && title="$(basename "${cwd:-claude}")"
  seq="$(printf '\033]0;%s ✳ %s\007' "$emoji" "$title")"
  printf '%s' "$seq" | jq -Rsc '{terminalSequence: .}'
  if [ "$kind" = "blocked" ] || [ "$kind" = "done" ]; then
    bridge="$HOME/.claude/vscode-bridge"
    mkdir -p "$bridge" 2>/dev/null || true
    jq -nc --arg s "$kind" --arg c "$cwd" --arg t "$title" \
      --arg term "${CLAUDE_COCKPIT_TERM_ID:-}" --argjson ts "$(date +%s)" \
      '{state:$s, cwd:$c, title:$t, term:$term, ts:$ts}' >> "$bridge/events.jsonl" 2>/dev/null || true
  fi
else
  # No python3/jq: static title, no notification events. The %s arguments are
  # passed literally (not format-expanded), keeping the JSON escapes intact.
  printf '{"terminalSequence":"%s]0;%s ✳ claude%s"}' '\u001b' "$emoji" '\u0007'
fi
