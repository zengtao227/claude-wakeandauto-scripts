#!/usr/bin/env bash
# 05:00 wake job for a persistent, Telegram-bridged Claude Code tmux session.
#
# This does NOT spawn a one-shot `claude --print` call. It assumes a
# long-running interactive session (see start-claude.sh) is already talking
# to you over Telegram, and its only job at 05:00 is to nudge that session:
# continue any unfinished work, or confirm it's idle and ready. Context is
# always preserved — this script never starts a fresh conversation.
set -euo pipefail

TMUX_SESSION="claude"
CHAT_ID="YOUR_CHAT_ID"  # set by install.sh or edit manually
TOKEN_ENV_PATH="$HOME/.claude/channels/telegram/.env"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/wake-claude-hallo.log"
# Shared with claude_rate_limit_watchdog.sh — both scripts can kill-session /
# send-keys on the same tmux session, and both run at :00 (wake job daily at
# 05:00, watchdog every 5 min). Without a shared lock the two can race.
LOCK_FILE="/tmp/claude-tmux-session.lock"
START_SCRIPT="$HOME/start-claude.sh"
DRY_RUN="0"
NO_SEND="0"
MAX_WAIT_FOR_REPLY=45
REPLY_STATUS=""
REPLY_TEXT=""

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN="1" ;;
    --no-send) NO_SEND="1" ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date -Is)" "$1"; }

read_token() {
  python3 - "$TOKEN_ENV_PATH" <<'PY'
import sys
from pathlib import Path
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    s = line.strip()
    if s.startswith("TELEGRAM_BOT_TOKEN="):
        print(s.split("=",1)[1].strip().strip("'\""))
        raise SystemExit(0)
raise SystemExit("TELEGRAM_BOT_TOKEN is missing")
PY
}

send_telegram() {
  local token="$1" text="$2"
  python3 - "$token" "$CHAT_ID" "$text" <<'PY'
import json, sys, urllib.parse, urllib.request
token, chat_id, text = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://api.telegram.org/bot{token}/sendMessage"
payload = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
with urllib.request.urlopen(urllib.request.Request(url, data=payload), timeout=15) as r:
    data = json.loads(r.read().decode())
if not data.get("ok"):
    raise SystemExit(f"Telegram send failed: {data}")
print(json.dumps({"ok": True, "message_id": (data.get("result") or {}).get("message_id")}, ensure_ascii=True))
PY
}

capture_pane() {
  tmux capture-pane -t "$TMUX_SESSION" -p -S -30 2>/dev/null || true
}

pane_is_busy() {
  local pane="$1"
  grep -qE 'esc to interrupt|… \([0-9]+m?[0-9]*s' <<< "$pane"
}

pane_is_rate_limited() {
  local pane="$1"
  grep -qiE 'session limit|rate-limit-options|usage limit' <<< "$pane"
}

pane_is_idle() {
  local pane="$1"
  # The empty prompt line is "❯" followed by U+00A0 (non-breaking space), not
  # a plain ASCII space — confirmed byte-for-byte against a live idle pane.
  # A plain ' *' here silently never matches and every idle day falls
  # through to the "unknown" branch. If you change this, verify against a
  # real pane capture with `cat -A` or Python repr(), not just eyeballing it.
  grep -qE $'^[❯>][ \xc2\xa0]*$' <<< "$pane"
}

# Pulls Claude's actual reply text out of the pane, taking everything after
# the last injected state-preserving prompt line and dropping spinner/status
# lines, so the Telegram status can quote what Claude actually said instead
# of just "a request was submitted".
extract_reply_since_prompt() {
  local pane="$1"
  # The injected prompt wraps across two rendered pane lines; both fragments
  # must reset the buffer or the second half gets misread as part of the reply.
  awk '
    /请保留当前上下文/ || /只回复 ?READY/ { seen=1; buf=""; next }
    seen { buf = buf $0 "\n" }
    END { printf "%s", buf }
  ' <<< "$pane" \
    | grep -vE '^[✻*][[:space:]]|^─+$|^[[:space:]]*$|manual mode on|Claude Code v|Channels \(experimental\)|inject directly in this session' \
    | grep -vE $'^[❯>][ \xc2\xa0]*$' \
    | sed -E 's/^●[[:space:]]*//' \
    | tr '\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | cut -c1-500
}

# Polls the pane for up to MAX_WAIT_FOR_REPLY seconds after a prompt was just
# sent. This deliberately does not block until completion — long-running
# tasks can take much longer than that — it only distinguishes "already
# replied" from "still working" at report time.
#
# A single "not busy" reading is not trusted: the empty-input-box shape that
# pane_is_idle looks for can still be on screen for a moment after Enter is
# sent, before the spinner/`esc to interrupt` status has rendered. Two
# consecutive non-busy, idle-shaped readings 3s apart are required before a
# reply is accepted as final.
wait_for_reply() {
  local waited=0 pane stable_hits=0
  REPLY_STATUS="busy"
  REPLY_TEXT=""
  while [ "$waited" -lt "$MAX_WAIT_FOR_REPLY" ]; do
    sleep 3
    waited=$((waited + 3))
    pane="$(capture_pane)"
    if pane_is_busy "$pane" || ! pane_is_idle "$pane"; then
      stable_hits=0
      continue
    fi
    stable_hits=$((stable_hits + 1))
    if [ "$stable_hits" -ge 2 ]; then
      REPLY_STATUS="idle"
      REPLY_TEXT="$(extract_reply_since_prompt "$pane")"
      log "Claude settled idle after ${waited}s (2 consecutive checks); reply captured"
      return 0
    fi
  done
  log "Claude still busy/unsettled ${MAX_WAIT_FOR_REPLY}s after the prompt; no reply captured yet"
  return 1
}

send_state_preserving_request() {
  local prompt
  prompt='请保留当前上下文：如果上一个任务尚未完成，请继续完成；如果没有未完成事项，请只回复 READY。'
  tmux send-keys -t "$TMUX_SESSION" "$prompt" Enter
  log "state-preserving Claude request submitted"
  wait_for_reply || true
}

# The rate-limit screen is a selection menu, not a text input (confirmed via
# claude_rate_limit_watchdog.sh, which un-sticks it with a bare Enter after
# the reset window passes). Typing straight into that menu is undefined, so
# clear it with Enter first and only send the prompt once the pane no longer
# matches the rate-limit pattern.
clear_rate_limit_menu_then_send() {
  local pane
  tmux send-keys -t "$TMUX_SESSION" Enter
  sleep 3
  pane="$(capture_pane)"
  if pane_is_rate_limited "$pane"; then
    log "Enter did not clear the rate-limit menu (reset window likely not reached yet); skipping prompt"
    MSG="Claude was still stuck at the usage-limit menu after 05:00; Enter did not clear it. Context was preserved; no prompt was sent."
    return 1
  fi
  if pane_is_busy "$pane"; then
    log "Enter cleared the rate-limit menu and Claude resumed work; skipping extra prompt"
    MSG="Claude resumed unfinished work after the usage-limit menu cleared. Context was preserved; no extra prompt was sent."
    return 0
  fi
  if pane_is_idle "$pane"; then
    send_state_preserving_request
    MSG="Claude was paused at a usage limit; Enter cleared the menu and a context-preserving request was submitted."
    return 0
  fi
  log "Enter cleared the rate-limit menu but pane state is unknown; skipping prompt"
  MSG="Claude left the usage-limit menu, but its pane state was unknown. Context was preserved; no prompt was sent."
  return 1
}

exec 9>"$LOCK_FILE"
if ! flock -w 30 9; then
  log "could not acquire tmux session lock within 30s (watchdog busy?); exiting" >> "$LOG_FILE"
  token="$(read_token 2>/dev/null || true)"
  if [ -n "${token:-}" ]; then
    send_telegram "$token" "05:00 wake job skipped: could not get the tmux lock within 30s. Nothing was sent; check the watchdog." >> "$LOG_FILE" 2>&1 || true
  fi
  exit 0
fi

{
  log "wake job started dry_run=$DRY_RUN no_send=$NO_SEND"

  if [ "$DRY_RUN" = "1" ]; then
    log "dry run complete; no action taken"
    exit 0
  fi

  # Preserve context unless a human explicitly clears it later. A pane alone
  # cannot reliably prove that an earlier task is complete.
  if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "tmux session '$TMUX_SESSION' not found; restarting via canonical launcher"
    if "$START_SCRIPT"; then
      sleep 2
      send_state_preserving_request
      MSG="Claude session was missing and was restarted. A context-preserving 05:00 request was submitted."
    else
      MSG="Claude session was missing and restart failed. No 05:00 Claude request was sent."
    fi
  else
    PANE="$(capture_pane)"
    if pane_is_busy "$PANE"; then
      log "Claude is busy; preserving in-flight work and skipping 05:00 request"
      MSG="Claude is still working at 05:00. Context was preserved; no new request was sent."
    elif pane_is_rate_limited "$PANE"; then
      clear_rate_limit_menu_then_send || true
    elif pane_is_idle "$PANE"; then
      send_state_preserving_request
      MSG="Context was preserved. A 05:00 Claude request was submitted: it will continue unfinished work, or reply READY if none remains."
    else
      log "Claude pane state is unknown; preserving context and skipping 05:00 request"
      MSG="Claude pane state was unknown at 05:00. Context was preserved; no new request was sent."
    fi
  fi

  if [ -n "$REPLY_STATUS" ]; then
    if [ "$REPLY_STATUS" = "idle" ]; then
      MSG="$MSG Claude's reply: ${REPLY_TEXT:-[empty]}"
    else
      MSG="$MSG (Still working ${MAX_WAIT_FOR_REPLY}s later — no reply captured yet; check the session for progress.)"
    fi
  fi

  log "status: $MSG"

  if [ "$NO_SEND" = "1" ]; then
    log "no-send mode; Telegram skipped"
    exit 0
  fi

  token="$(read_token)"
  send_result="$(send_telegram "$token" "$MSG")"
  log "Telegram send result: $send_result"
} >> "$LOG_FILE" 2>&1
