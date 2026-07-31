# claude-wakeandauto-scripts

Automation for Claude Code users who run long-lived sessions across a daily
quota reset:

- **VPS** (`vps/`): keeps a persistent, Telegram-bridged Claude Code `tmux`
  session alive — auto-restarts it if it dies, self-heals a dead Telegram
  poller, unsticks it after a rate-limit reset, and nudges it once a day at
  05:00 to continue any unfinished work (or confirm it's idle).
- **Mac** (`mac/`): at 05:00, injects "继续" (continue) into every open
  Claude Code window in iTerm2 — resuming any tasks that were paused when
  quota ran out. Falls back to writing directly to the TTY if the screen is
  locked (AppleScript can't reach a locked session).

Context is never discarded by either script — they resume or confirm-idle,
they don't start fresh conversations.

---

## Prerequisites

Both sides require:

- [Claude Code CLI](https://claude.ai/code) installed and logged in
- A Telegram bot connected to Claude Code (via the `telegram` plugin)
- Your **Telegram Chat ID** — find it by messaging [@userinfobot](https://t.me/userinfobot)

The **VPS side** additionally requires `tmux`.

The **Mac side** additionally requires:
- **iTerm2** as your terminal (uses AppleScript injection)
- macOS accessibility permission granted to `osascript` / iTerm2

---

## VPS — persistent Telegram-bridged session

**What it does:**

```
vps/start-claude.sh
    Canonical launcher. Kills any existing `claude` tmux session, starts a
    fresh one running `claude --channels plugin:telegram@...`, and verifies
    the Telegram MCP actually connected before giving up (retries 3x).
    Every other script calls this instead of re-implementing the launch
    sequence, so they can't drift out of sync with each other.

vps/claude_rate_limit_watchdog.sh   (cron, every 5 min)
    1. tmux session gone      -> restart via start-claude.sh
    2. Telegram poller dead   -> alert, auto-restart once the session is
                                  idle (never interrupts in-flight work)
    3. stuck at rate-limit    -> send Enter once the reset window has passed

vps/wake_claude_hallo.sh   (cron, 05:00 daily)
    Reads the current pane state (idle / busy / rate-limited / missing) and
    reacts accordingly: if busy, leaves it alone; if idle, sends a
    context-preserving "continue unfinished work, or reply READY" prompt and
    waits briefly to capture the reply; if stuck at a rate limit, clears the
    menu once past reset; if the session is gone, restarts it first. Always
    reports the outcome to Telegram.
```

`wake_claude_hallo.sh` and `claude_rate_limit_watchdog.sh` share a lock file
(`/tmp/claude-tmux-session.lock`) — both can send keys into the same tmux
session and both can run at `:00`, so without the lock they can race.

**Install:**

```bash
git clone https://github.com/zengtao227/claude-wakeandauto-scripts.git
cd claude-wakeandauto-scripts/vps
chmod +x install.sh
./install.sh
```

The installer copies all three scripts, patches your chat ID into the two
that send Telegram messages, and adds both cron entries. It does **not**
start the tmux session for you — after installing, run once:

```bash
~/start-claude.sh
```

**Test immediately:**
```bash
bash ~/.claude/scripts/wake_claude_hallo.sh
tail -f ~/.claude/logs/wake-claude-hallo.log
tail -f ~/.claude/logs/rate-limit-watchdog.log
```

**Adjust timezone / rate-limit reset window:**
Edit `RESET_HOUR`, `RESET_MIN`, and `RESET_TZ` at the top of
`claude_rate_limit_watchdog.sh` to match when your quota actually resets.
The wake-job cron line runs at 05:00 server local time — prefix it with
`CRON_TZ=Europe/Zurich` (or your zone) in crontab if the server isn't
already in your timezone.

**Optional — a second bot for watchdog alerts:**
If the primary bot's Telegram poller dies, an alert sent through that same
bot might not deliver either. `claude_rate_limit_watchdog.sh` reads its
alert token from `~/.claude/channels/telegram-backup/.env` — point that at
a second bot's token for real redundancy, or leave it pointed at the same
file as the main session if you don't want to run a second bot.

---

## Mac — Auto-resume open Claude sessions

**What it does:**
Every day at 05:00, scans all running `claude` processes, finds their
iTerm2 terminal sessions via AppleScript, and sends "继续" as keyboard
input to each one. If a session's screen is locked, AppleScript can't write
to it — the script falls back to writing directly to the TTY device, which
still works. Also sends a Telegram summary of how many sessions were woken.

**Install:**

```bash
git clone https://github.com/zengtao227/claude-wakeandauto-scripts.git
cd claude-wakeandauto-scripts/mac
chmod +x install.sh
./install.sh
```

The installer will:
1. Copy `wake_claude_jixu.sh` to `~/.claude/scripts/`
2. Ask for your Telegram Chat ID
3. Install and load the launchd job (`~/Library/LaunchAgents/com.anthropic.claude.wake-jixu.plist`)

**Test immediately:**
```bash
zsh ~/.claude/scripts/wake_claude_jixu.sh
tail -f ~/.claude/logs/wake-claude-jixu.log
```

**Note on accessibility permissions:**
The first time `osascript` controls iTerm2, macOS may prompt for
accessibility access. Grant it in:
*System Settings → Privacy & Security → Accessibility*

---

## How it works

```
Daily quota reset
        │
        ▼
   05:00 local time
        │
        ├── VPS: wake_claude_hallo.sh reads pane state → nudges the
        │        persistent tmux session (or restarts it) → Telegram report
        │        (meanwhile claude_rate_limit_watchdog.sh keeps that same
        │        session alive every 5 minutes, all day)
        │
        └── Mac: launchd → find claude TTYs → AppleScript inject "继续"
                 (falls back to direct TTY write if locked) → Telegram summary
```

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| VPS: tmux session never comes up | Run `~/start-claude.sh` manually and read `~/.claude/logs/start-claude.log` |
| VPS: Telegram poller keeps dying | Check `~/.claude/logs/rate-limit-watchdog.log`; a second `claude` process elsewhere can steal the poll lock |
| VPS: 401 error | Run `claude /login` to refresh the OAuth token |
| Mac: no sessions found | Make sure Claude Code windows are open in iTerm2 (not Terminal.app) |
| Mac: AppleScript error | Grant accessibility permission to iTerm2 / osascript in System Settings |
| Mac token expired | Run `launchctl kickstart -k gui/$(id -u)/com.anthropic.claude.telegram` |
| Telegram not sending | Check `TELEGRAM_BOT_TOKEN` in `~/.claude/channels/telegram/.env` |

---

## License

MIT
