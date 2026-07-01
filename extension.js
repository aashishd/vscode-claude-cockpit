// Claude Cockpit — launch Claude Code terminals, traffic-light tab titles,
// and notifications when Claude blocks or finishes.
//
// The lights themselves are produced by Claude Code hooks (installed via the
// "Install Claude Hooks" command): each hook emits a terminalSequence that
// sets the tab title, and appends blocked/done events to a bridge file that
// this extension watches to raise notifications.
const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");

const BRIDGE_DIR = path.join(os.homedir(), ".claude", "vscode-bridge");
const BRIDGE_FILE = path.join(BRIDGE_DIR, "events.jsonl");
const HOOKS_DIR = path.join(os.homedir(), ".claude", "hooks");
const HELPER_NAME = "cc-tab-title.sh";
const SETTINGS_FILE = path.join(os.homedir(), ".claude", "settings.json");
const MAX_BRIDGE_BYTES = 1024 * 1024;

// Hook events installed into ~/.claude/settings.json: event -> [emoji, kind].
const HOOK_EVENTS = {
  SessionStart: ["🟢", "init"],
  UserPromptSubmit: ["🟡", "processing"],
  PostToolUse: ["🟡", "processing"],
  PermissionRequest: ["🔴", "blocked"],
  Elicitation: ["🔴", "blocked"],
  Stop: ["🟢", "done"],
};

/** Terminals created by this extension, used by the Focus button. */
const ownTerminals = new Set();

function config() {
  return vscode.workspace.getConfiguration("claudeCockpit");
}

function terminalOptions() {
  const cmd = config().get("command", "claude");
  // Stamp an initial title so the tab is identifiable before any hook fires.
  const stamp = "printf '\\033]0;✳ claude\\007'; ";
  const fallbackShell = process.platform === "darwin" ? "/bin/zsh" : "/bin/bash";
  // No `name`: an extension-provided name becomes a STATIC title that
  // permanently overrides OSC title sequences, which would kill the
  // traffic-light tab titles. The launch stamp names the tab instead.
  return {
    shellPath: vscode.env.shell || fallbackShell,
    // -l -i so the user's interactive rc files (PATH entries like
    // ~/.local/bin) are sourced before launching the agent.
    shellArgs: ["-l", "-i", "-c", stamp + cmd],
    iconPath: new vscode.ThemeIcon("sparkle"),
    color: new vscode.ThemeColor("terminal.ansiMagenta"),
  };
}

function launchClaude() {
  const terminal = vscode.window.createTerminal(terminalOptions());
  ownTerminals.add(terminal);
  terminal.show();
}

function focusClaudeTerminal() {
  for (const t of [...ownTerminals].reverse()) {
    if (t.exitStatus === undefined) {
      t.show();
      return;
    }
  }
  vscode.commands.executeCommand("workbench.action.terminal.focus");
}

// ---------------------------------------------------------------------------
// Bridge watcher: tail ~/.claude/vscode-bridge/events.jsonl for hook events.
// ---------------------------------------------------------------------------

function eventBelongsToThisWindow(cwd) {
  if (!cwd) return false;
  const folders = vscode.workspace.workspaceFolders || [];
  return folders.some(
    (f) => cwd === f.uri.fsPath || cwd.startsWith(f.uri.fsPath + path.sep)
  );
}

function handleBridgeEvent(event) {
  if (!eventBelongsToThisWindow(event.cwd)) return;
  const title = event.title || "claude";
  if (event.state === "blocked" && config().get("notifyOnBlocked", true)) {
    vscode.window
      .showWarningMessage(`🔴 Claude needs your input — ${title}`, "Focus terminal")
      .then((choice) => choice && focusClaudeTerminal());
  } else if (event.state === "done" && config().get("notifyOnDone", true)) {
    vscode.window
      .showInformationMessage(`🟢 Claude finished — ${title}`, "Focus terminal")
      .then((choice) => choice && focusClaudeTerminal());
  }
}

function startBridgeWatcher() {
  fs.mkdirSync(BRIDGE_DIR, { recursive: true });
  // Start at the current end of file: only react to events after activation.
  let offset = 0;
  try {
    offset = fs.statSync(BRIDGE_FILE).size;
  } catch {
    /* file does not exist yet */
  }

  const drain = () => {
    let stat;
    try {
      stat = fs.statSync(BRIDGE_FILE);
    } catch {
      return;
    }
    if (stat.size < offset) offset = 0; // file was truncated
    if (stat.size === offset) return;
    const buffer = Buffer.alloc(stat.size - offset);
    const fd = fs.openSync(BRIDGE_FILE, "r");
    try {
      fs.readSync(fd, buffer, 0, buffer.length, offset);
    } finally {
      fs.closeSync(fd);
    }
    offset = stat.size;
    for (const line of buffer.toString("utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        handleBridgeEvent(JSON.parse(line));
      } catch {
        /* skip malformed lines */
      }
    }
    if (offset > MAX_BRIDGE_BYTES) {
      try {
        fs.truncateSync(BRIDGE_FILE, 0);
        offset = 0;
      } catch {
        /* another window may have truncated already */
      }
    }
  };

  const watcher = fs.watch(BRIDGE_DIR, (_type, filename) => {
    if (filename === path.basename(BRIDGE_FILE)) drain();
  });
  return { dispose: () => watcher.close() };
}

// ---------------------------------------------------------------------------
// Hooks installer: merge title/notification hooks into ~/.claude/settings.json
// ---------------------------------------------------------------------------

async function installHooks(context) {
  const choice = await vscode.window.showWarningMessage(
    "Claude Cockpit will:\n" +
      `1. Copy its hook helper to ~/.claude/hooks/${HELPER_NAME}\n` +
      "2. Add tab-title/notification hooks and CLAUDE_CODE_DISABLE_TERMINAL_TITLE=1 " +
      "to ~/.claude/settings.json (a timestamped backup is created first).\n\n" +
      "Existing hooks are preserved. Continue?",
    { modal: true },
    "Install"
  );
  if (choice !== "Install") return;

  try {
    // 1. Helper script.
    fs.mkdirSync(HOOKS_DIR, { recursive: true });
    const helperDest = path.join(HOOKS_DIR, HELPER_NAME);
    fs.copyFileSync(context.asAbsolutePath(path.join("resources", HELPER_NAME)), helperDest);
    fs.chmodSync(helperDest, 0o755);

    // 2. Settings merge (additive, idempotent).
    let settings = {};
    if (fs.existsSync(SETTINGS_FILE)) {
      settings = JSON.parse(fs.readFileSync(SETTINGS_FILE, "utf8"));
      const backup = `${SETTINGS_FILE}.bak-${new Date().toISOString().replace(/[:.]/g, "-")}`;
      fs.copyFileSync(SETTINGS_FILE, backup);
    }
    settings.env = settings.env || {};
    settings.env.CLAUDE_CODE_DISABLE_TERMINAL_TITLE = "1";
    settings.hooks = settings.hooks || {};
    for (const [event, [emoji, kind]] of Object.entries(HOOK_EVENTS)) {
      const entries = settings.hooks[event] || [];
      // Idempotence: skip if this event already invokes our helper.
      if (JSON.stringify(entries).includes(HELPER_NAME)) continue;
      entries.push({
        hooks: [
          {
            type: "command",
            command: `bash "$HOME/.claude/hooks/${HELPER_NAME}" '${emoji}' ${kind}`,
          },
        ],
      });
      settings.hooks[event] = entries;
    }
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(settings, null, 2) + "\n");

    vscode.window.showInformationMessage(
      "Claude hooks installed. Start a new Claude Code session to see the lights."
    );
  } catch (error) {
    vscode.window.showErrorMessage(`Claude Cockpit hook install failed: ${error.message}`);
  }
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

function activate(context) {
  context.subscriptions.push(
    vscode.commands.registerCommand("claudeCockpit.launch", launchClaude),
    vscode.commands.registerCommand("claudeCockpit.installHooks", () => installHooks(context)),
    vscode.window.registerTerminalProfileProvider("claude-cockpit.claude", {
      provideTerminalProfile: () => new vscode.TerminalProfile(terminalOptions()),
    }),
    vscode.window.onDidCloseTerminal((t) => ownTerminals.delete(t)),
    startBridgeWatcher()
  );

  const statusItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusItem.text = "$(sparkle) cc";
  statusItem.tooltip = "Launch Claude Code";
  statusItem.command = "claudeCockpit.launch";
  const syncStatusItem = () => {
    if (config().get("statusBarButton", true)) statusItem.show();
    else statusItem.hide();
  };
  syncStatusItem();
  context.subscriptions.push(
    statusItem,
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration("claudeCockpit.statusBarButton")) syncStatusItem();
    })
  );
}

function deactivate() {}

module.exports = { activate, deactivate };
