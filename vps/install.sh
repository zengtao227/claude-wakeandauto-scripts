#!/bin/bash
# Install the VPS side: a persistent, Telegram-bridged Claude Code tmux
# session plus two cron jobs that keep it alive and nudge it at 05:00.
#
# Prerequisites:
#   - Claude Code CLI installed and logged in (`claude /login`)
#   - tmux installed
#   - Telegram bot token in ~/.claude/channels/telegram/.env
#     (line: TELEGRAM_BOT_TOKEN=...)
#   - Claude Code telegram plugin configured
#   - Optional: a second bot's token in
#     ~/.claude/channels/telegram-backup/.env for watchdog alerts to survive
#     a dead primary poller (see claude_rate_limit_watchdog.sh)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing the Claude Code VPS bot: start-claude.sh, wake_claude_hallo.sh, claude_rate_limit_watchdog.sh..."

mkdir -p "$HOME/.claude/scripts"
mkdir -p "$HOME/.claude/logs"

cp "$SCRIPT_DIR/start-claude.sh" "$HOME/start-claude.sh"
chmod +x "$HOME/start-claude.sh"

cp "$SCRIPT_DIR/wake_claude_hallo.sh" "$HOME/.claude/scripts/wake_claude_hallo.sh"
chmod +x "$HOME/.claude/scripts/wake_claude_hallo.sh"

cp "$SCRIPT_DIR/claude_rate_limit_watchdog.sh" "$HOME/.claude/scripts/claude_rate_limit_watchdog.sh"
chmod +x "$HOME/.claude/scripts/claude_rate_limit_watchdog.sh"

# Patch CHAT_ID in both scripts that send Telegram messages
read -p "Enter your Telegram chat ID: " CHAT_ID
sed -i "s/CHAT_ID=\"YOUR_CHAT_ID\"/CHAT_ID=\"$CHAT_ID\"/" \
    "$HOME/.claude/scripts/wake_claude_hallo.sh" \
    "$HOME/.claude/scripts/claude_rate_limit_watchdog.sh"

# Add crontab entries:
#   - wake job at 05:00 server local time (adjust CRON_TZ if needed)
#   - watchdog every 5 minutes
WAKE_LINE="0 5 * * * $HOME/.claude/scripts/wake_claude_hallo.sh >> $HOME/.claude/logs/wake-claude-hallo.cron.log 2>&1"
WATCHDOG_LINE="*/5 * * * * $HOME/.claude/scripts/claude_rate_limit_watchdog.sh"
(
  crontab -l 2>/dev/null | grep -v wake_claude_hallo | grep -v claude_rate_limit_watchdog
  echo "$WAKE_LINE"
  echo "$WATCHDOG_LINE"
) | crontab -

echo "Done."
echo
echo "This does NOT start the tmux session for you — run it once manually:"
echo "  $HOME/start-claude.sh"
echo
echo "After that, the watchdog (every 5 min) keeps the session and its"
echo "Telegram poller alive, and the wake job (05:00 daily) nudges it to"
echo "continue unfinished work or confirm it's idle."
echo
echo "Test the wake job immediately: bash ~/.claude/scripts/wake_claude_hallo.sh"
echo "Logs: ~/.claude/logs/wake-claude-hallo.log and ~/.claude/logs/rate-limit-watchdog.log"
