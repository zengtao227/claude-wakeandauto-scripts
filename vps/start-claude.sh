#!/bin/bash
# Canonical launcher for the Telegram-connected Claude Code bot session.
# Verifies the telegram MCP actually connected (it can transiently fail to
# grab the getUpdates poll lock right after a kill), retrying a few times
# before giving up. This is the single source of truth for the launch
# sequence — claude_rate_limit_watchdog.sh and wake_claude_hallo.sh both
# call this script rather than re-implementing it, so they never drift out
# of sync with each other.
LOG="$HOME/.claude/logs/start-claude.log"
mkdir -p "$HOME/.claude/logs"
log() { printf '[%s] %s\n' "$(date -Is)" "$1" >> "$LOG"; }

MAX_ATTEMPTS=3
TMUX_SESSION="claude"
CLAUDE_MODEL="claude-sonnet-5"

for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  sleep 2
  tmux new-session -d -s "$TMUX_SESSION" -x 220 -y 50
  tmux send-keys -t "$TMUX_SESSION" "command claude --model $CLAUDE_MODEL --channels plugin:telegram@claude-plugins-official" Enter
  sleep 8
  tmux send-keys -t "$TMUX_SESSION" '1' Enter
  sleep 5
  tmux send-keys -t "$TMUX_SESSION" '/mcp' Enter
  sleep 3
  STATUS=$(tmux capture-pane -t "$TMUX_SESSION" -p)
  tmux send-keys -t "$TMUX_SESSION" Escape

  if echo "$STATUS" | grep -q 'plugin:telegram:telegram.*connected'; then
    log "attempt $attempt: telegram MCP connected."
    exit 0
  fi

  log "attempt $attempt: telegram MCP not connected, retrying..."
  sleep 2
done

log "all $MAX_ATTEMPTS attempts failed to connect telegram MCP. Giving up — bot will not receive Telegram messages until manually fixed."
exit 1
