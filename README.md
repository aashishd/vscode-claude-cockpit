# Claude Cockpit

Launch [Claude Code](https://code.claude.com) terminals from VS Code, see a
traffic light + topic on every Claude terminal tab, and get notified when
Claude needs you.

| Light | Meaning |
|---|---|
| 🟡 | Claude is processing |
| 🔴 | Claude is blocked waiting for your input (permission prompt, form) |
| 🟢 | Claude finished responding |

The tab title becomes `<light> ✳ <topic>`, where `<topic>` is the session
title Claude generates (e.g. `🟢 ✳ Fix login race condition`).

## Features

- **Launcher** — status-bar button `✳ cc`, Command Palette entry
  (`⌘⇧P` → type `cc`), and a "Claude Code" terminal profile in the terminal
  dropdown. All open a terminal running `claude` through your login shell.
- **Traffic-light tab titles** — driven by Claude Code hooks emitting
  `terminalSequence` title updates, including the auto-generated topic name.
- **Notifications** — a VS Code popup when Claude is blocked on your input
  (🔴) and when it finishes (🟢), each with a *Focus terminal* button. Only
  the window whose workspace contains the Claude session gets the popup.

## Requirements

- Claude Code **≥ 2.1.141** (hook `terminalSequence` support)
- macOS or Linux, VS Code ≥ 1.90
- `python3` or `jq` on PATH (used by the hook helper; falls back to a static
  title without them)

## Install

1. Download the `.vsix` from [Releases](https://github.com/aashishd/vscode-claude-cockpit/releases).
2. VS Code → Extensions view → `···` menu → **Install from VSIX…**
3. Reload the window.

## Setup (one time)

Run **`⌘⇧P` → "Claude Cockpit: Install Claude Hooks"**. This:

1. Copies the hook helper to `~/.claude/hooks/cc-tab-title.sh`.
2. Merges into `~/.claude/settings.json` (timestamped backup first,
   existing hooks preserved):
   - hooks for `SessionStart` / `UserPromptSubmit` / `PostToolUse` /
     `PermissionRequest` / `Elicitation` / `Stop` that set the tab title and
     emit notification events;
   - `CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1` so Claude's built-in title
     writes don't fight the lights.

Start a **new** Claude Code session afterwards — hooks load at session start.

## Settings

| Setting | Default | Description |
|---|---|---|
| `claudeCockpit.command` | `claude` | Command used to launch Claude Code |
| `claudeCockpit.notifyOnBlocked` | `true` | Popup when Claude waits for input |
| `claudeCockpit.notifyOnDone` | `true` | Popup when Claude finishes |
| `claudeCockpit.statusBarButton` | `true` | Show the `✳ cc` status-bar button |

The extension also sets the default of `terminal.integrated.tabs.title` to
`${sequence}` so program-set titles are shown; your own value wins if you have
one configured.

## How it works

Claude Code hooks (installed by the setup command) run on session lifecycle
events. Each invocation of `~/.claude/hooks/cc-tab-title.sh`:

1. reads the session topic from the transcript's `ai-title` records,
2. prints `{"terminalSequence": "<OSC 0 title>"}` which Claude Code emits to
   the terminal — VS Code renders it as the tab title via `${sequence}`,
3. for blocked/done states, appends an event to
   `~/.claude/vscode-bridge/events.jsonl`, which the extension tails to raise
   the popups.

## Uninstall

- Uninstall the extension.
- Remove the Cockpit entries from `hooks` and the
  `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` env from `~/.claude/settings.json`
  (or restore the `settings.json.bak-*` backup), and delete
  `~/.claude/hooks/cc-tab-title.sh`.

## License

MIT
