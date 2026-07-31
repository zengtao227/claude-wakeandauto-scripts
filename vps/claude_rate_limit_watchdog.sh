#!/usr/bin/env bash
# Watchdog for the tmux 'claude' bot session (run via cron every 5 min):
#   1. tmux session gone            -> restart via start-claude.sh
#   2. telegram poller dead         -> alert; auto-restart only when the
#      session is idle (a busy session would lose in-flight work). Poller
#      death is otherwise invisible: with no poller, inbound messages never
#      reach the MCP log, so a "did we reply in time" monitor sees nothing
#      to complain about — a dead poller looks identical to "no messages."
#   3. stuck at rate-limit menu     -> send Enter after the reset window
TMUX_SESSION="claude"
LOG="$HOME/.claude/logs/rate-limit-watchdog.log"
RESET_HOUR=2
RESET_MIN=5
RESET_TZ="Europe/Zurich"  # match this to whatever timezone your quota resets in
# Shared with wake_claude_hallo.sh (its 05:00 cron run overlaps this every-
# 5-min job). Non-blocking here: if the other script holds it, skip this
# cycle rather than race it for kill-session/send-keys on the same session.
LOCK_FILE="/tmp/claude-tmux-session.lock"
START_SCRIPT="$HOME/start-claude.sh"

CHAT_ID="YOUR_CHAT_ID"  # set by install.sh or edit manually
# Alerts are sent through a SEPARATE bot/token from the one the main session
# uses, on purpose: if the primary bot's poller has died, an alert sent
# through that same bot might also fail to deliver. Point this at a second
# bot's token file (must contain a line `TELEGRAM_BOT_TOKEN=...`). If you
# don't want to run a second bot, point it at the same file as the main
# session — you lose that redundancy but the watchdog still works.
BACKUP_ENV="$HOME/.claude/channels/telegram-backup/.env"

BOT_PID_FILE="$HOME/.claude/channels/telegram/bot.pid"
# two consecutive dead checks (~10 min) before acting, so a poller that is
# mid-restart (start-claude.sh rewrites bot.pid a few seconds in) is not
# treated as an incident
POLLER_STRIKES_FILE=/var/tmp/claude_poller_strikes
POLLER_ALERTED_FILE=/var/tmp/claude_poller_alerted
POLLER_RESTART_COUNT_FILE=/var/tmp/claude_poller_restart_count
# once an incident has been alerted, only re-alert every N failed restart
# attempts instead of every cycle, so a persistent (non-self-healing) cause
# doesn't spam identical alerts for hours
ESCALATE_EVERY=5

log() { printf '[%s] %s\n' "$(date -Is)" "$1" >> "$LOG"; }

send_backup_alert() {
    local token
    token=$(grep -m1 '^TELEGRAM_BOT_TOKEN=' "$BACKUP_ENV" 2>/dev/null | cut -d= -f2- | tr -d "\"'")
    if [ -z "$token" ]; then
        log "backup bot token missing in $BACKUP_ENV; cannot send alert"
        return 1
    fi
    curl -fsS -m 10 "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${CHAT_ID}" \
        --data-urlencode "text=$1" >/dev/null 2>&1
}

# --- 1. tmux session existence ---
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    # Session gone entirely — restart via the canonical launch script so the
    # model/channels/MCP-verify logic lives in one place instead of being
    # re-implemented (and drifting out of sync) here.
    log "tmux session '$TMUX_SESSION' not found. Restarting via start-claude.sh..."
    if flock -n "$LOCK_FILE" "$START_SCRIPT"; then
        log "start-claude.sh finished successfully."
    else
        log "start-claude.sh via flock failed or lock was busy (exit $?)."
    fi
    exit 0
fi

PANE_CONTENT=$(tmux capture-pane -t "$TMUX_SESSION" -p -S -30 2>/dev/null)

# --- 2. telegram poller liveness ---
poller_alive=0
if [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE" 2>/dev/null)" 2>/dev/null; then
    poller_alive=1
fi

if [ "$poller_alive" -eq 1 ]; then
    if [ -f "$POLLER_ALERTED_FILE" ]; then
        send_backup_alert "✅ [Watchdog] Telegram poller recovered."
        log "poller recovered — sent recovery alert"
    fi
    rm -f "$POLLER_STRIKES_FILE" "$POLLER_ALERTED_FILE" "$POLLER_RESTART_COUNT_FILE"
else
    strikes=$(( $(cat "$POLLER_STRIKES_FILE" 2>/dev/null || echo 0) + 1 ))
    echo "$strikes" > "$POLLER_STRIKES_FILE"
    log "telegram poller dead (bot.pid missing or stale), strike $strikes"
    if [ "$strikes" -ge 2 ]; then
        # busy heuristic: an active turn shows a spinner line like
        # "· Working… (25s · ..." or the "esc to interrupt" hint
        if echo "$PANE_CONTENT" | grep -qE 'esc to interrupt|… \([0-9]+m?[0-9]*s'; then
            if [ ! -f "$POLLER_ALERTED_FILE" ]; then
                send_backup_alert "⚠️ [Watchdog] Telegram poller died and the session is busy — deferring restart until it's idle so in-flight work isn't lost."
                touch "$POLLER_ALERTED_FILE"
                log "session busy — alert sent, restart deferred until idle"
            fi
        else
            restart_count=$(( $(cat "$POLLER_RESTART_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
            echo "$restart_count" > "$POLLER_RESTART_COUNT_FILE"
            if [ ! -f "$POLLER_ALERTED_FILE" ]; then
                send_backup_alert "🔄 [Watchdog] Telegram poller died; session is idle, auto-restarting."
                touch "$POLLER_ALERTED_FILE"
            elif [ $(( restart_count % ESCALATE_EVERY )) -eq 0 ]; then
                send_backup_alert "⚠️ [Watchdog] Telegram poller still down after ${restart_count} restart attempts — may need manual attention."
                log "escalation alert sent (restart attempt $restart_count)"
            fi
            log "poller dead and session idle — restarting via start-claude.sh (attempt $restart_count)"
            if flock -n "$LOCK_FILE" "$START_SCRIPT"; then
                log "start-claude.sh finished successfully."
            else
                log "start-claude.sh via flock failed or lock was busy (exit $?)."
            fi
            rm -f "$POLLER_STRIKES_FILE"
        fi
        exit 0
    fi
fi

# --- 3. rate-limit menu ---
if ! echo "$PANE_CONTENT" | grep -q 'session limit\|rate-limit-options'; then
    exit 0  # not stuck, nothing to do
fi

# Stuck at rate limit — check if reset window has passed
CURRENT_HOUR=$(TZ="$RESET_TZ" date +%-H)
CURRENT_MIN=$(TZ="$RESET_TZ" date +%-M)

if [ "$CURRENT_HOUR" -gt "$RESET_HOUR" ] || \
   ([ "$CURRENT_HOUR" -eq "$RESET_HOUR" ] && [ "$CURRENT_MIN" -ge "$RESET_MIN" ]); then
    log "Rate limit reset window passed (now ${CURRENT_HOUR}:${CURRENT_MIN} $RESET_TZ). Sending Enter to resume."
    if flock -n "$LOCK_FILE" tmux send-keys -t "$TMUX_SESSION" Enter; then
        log "Enter sent. Claude should resume processing queued messages."
    else
        log "could not get tmux lock to send Enter (wake job busy?); will retry next cycle."
    fi
else
    log "Claude stuck at rate limit, but reset not yet (now ${CURRENT_HOUR}:${CURRENT_MIN} $RESET_TZ). Waiting."
fi
