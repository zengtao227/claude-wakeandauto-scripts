#!/bin/zsh
# Install wake_claude_jixu on macOS
# Prerequisites:
#   - Claude Code CLI installed at ~/.local/bin/claude
#   - iTerm2 as terminal (required for AppleScript injection)
#   - Telegram bot token in ~/.claude/channels/telegram/.env
#   - Claude Code telegram plugin configured

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="$HOME"

echo "Installing wake_claude_jixu..."

# Create directories
mkdir -p "$HOME_DIR/.claude/scripts"
mkdir -p "$HOME_DIR/.claude/logs"

# Copy script
cp "$SCRIPT_DIR/wake_claude_jixu.sh" "$HOME_DIR/.claude/scripts/wake_claude_jixu.sh"
chmod +x "$HOME_DIR/.claude/scripts/wake_claude_jixu.sh"

# Patch CHAT_ID in script
read "CHAT_ID?Enter your Telegram chat ID: "
sed -i '' "s/CHAT_ID=\"YOUR_CHAT_ID\"/CHAT_ID=\"$CHAT_ID\"/" \
    "$HOME_DIR/.claude/scripts/wake_claude_jixu.sh"

# Install launchd plist
PLIST_SRC="$SCRIPT_DIR/com.anthropic.claude.wake-jixu.plist"
PLIST_DST="$HOME_DIR/Library/LaunchAgents/com.anthropic.claude.wake-jixu.plist"

sed "s|YOUR_HOME|$HOME_DIR|g" "$PLIST_SRC" > "$PLIST_DST"

# Load
launchctl unload "$PLIST_DST" 2>/dev/null || true
launchctl load "$PLIST_DST"

echo "Done. Scheduled daily at 05:00."
echo "Test run: zsh ~/.claude/scripts/wake_claude_jixu.sh"
echo "Logs: ~/.claude/logs/wake-claude-jixu.log"
