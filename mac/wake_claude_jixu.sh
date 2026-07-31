#!/bin/zsh
# Wake Claude sessions at 05:00 — inject "继续" into every open Claude window.
#
# Mechanism:
#   1. Find all claude process TTYs via ps
#   2. Try AppleScript (iTerm2) first; fall back to direct TTY write if screen is locked
#   3. Report results via Telegram
#
# Note: deliberately does NOT use `set -euo pipefail`. In zsh,
# result=$(osascript ...) under `set -e` exits the whole script silently the
# moment osascript fails (e.g. the screen is locked) — swallowing every
# subsequent log line and the Telegram report along with it.

CHAT_ID="YOUR_CHAT_ID"  # set by install.sh or edit manually
TOKEN_ENV_PATH="$HOME/.claude/channels/telegram/.env"
LOG_DIR="$HOME/.claude/logs"
LOG_FILE="$LOG_DIR/wake-claude-jixu.log"
LOCK_DIR="/tmp/claude-wake-jixu.lock"

mkdir -p "$LOG_DIR"

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$1"
}

read_token() {
    python3 - "$TOKEN_ENV_PATH" <<'PY'
from __future__ import annotations
import sys
from pathlib import Path

path: Path = Path(sys.argv[1])
for line in path.read_text(encoding="utf-8").splitlines():
    stripped: str = line.strip()
    if stripped.startswith("TELEGRAM_BOT_TOKEN="):
        token: str = stripped.split("=", 1)[1].strip().strip("'\"")
        if token:
            print(token)
            raise SystemExit(0)
raise SystemExit("TELEGRAM_BOT_TOKEN not found")
PY
}

send_telegram() {
    local token="$1"
    local text="$2"
    python3 - "$token" "$CHAT_ID" "$text" <<'PY'
from __future__ import annotations
import json, sys, urllib.parse, urllib.request

token: str = sys.argv[1]
chat_id: str = sys.argv[2]
text: str = sys.argv[3]
url: str = f"https://api.telegram.org/bot{token}/sendMessage"
payload: bytes = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
req: urllib.request.Request = urllib.request.Request(url, data=payload, method="POST")
with urllib.request.urlopen(req, timeout=15) as r:
    data: dict = json.loads(r.read().decode("utf-8"))
if not data.get("ok"):
    raise SystemExit(f"Telegram failed: {data}")
PY
}

# Try AppleScript first; if it fails (e.g. screen locked), fall back to direct PTY write.
# Returns: "ok", "fallback_ok", or "failed:<reason>"
inject_continue() {
    local tty_path="$1"

    # ── Attempt 1: AppleScript via iTerm2 ────────────────────────────────────
    local as_result as_exit
    as_result=$(osascript <<APPLESCRIPT 2>&1
tell application "iTerm2"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if tty of s is "$tty_path" then
                    tell s to write text "继续"
                    return "ok"
                end if
            end repeat
        end repeat
    end repeat
    return "not_found"
end tell
APPLESCRIPT
    )
    as_exit=$?

    if [[ $as_exit -eq 0 && "$as_result" == "ok" ]]; then
        echo "ok"
        return
    fi

    log "  AppleScript result='$as_result' exit=$as_exit — trying TTY fallback" >&2

    # ── Attempt 2: direct write to PTY device ────────────────────────────────
    # Works when screen is locked (macOS blocks AppleScript UI scripting then,
    # but a plain write to the PTY device still reaches the shell).
    # Writes "继续\n" as raw bytes to the TTY; Claude Code reads it as user input.
    if [[ -w "$tty_path" ]]; then
        printf '继续\n' >> "$tty_path" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "fallback_ok"
            return
        fi
    fi

    echo "failed:as_exit=${as_exit} as_result=${as_result}"
}

# ── Lock guard ────────────────────────────────────────────────────────────────
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "another wake-jixu job is already running; exiting" >> "$LOG_FILE"
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

{
    log "wake-jixu job started"

    # ── Find all Claude process TTYs ─────────────────────────────────────────
    CLAUDE_TTYS=()
    while IFS= read -r line; do
        CLAUDE_TTYS+=("$line")
    done < <(ps -e -o tty,comm 2>/dev/null | awk '$2 == "claude" && $1 != "??" {print "/dev/" $1}')

    if [ ${#CLAUDE_TTYS[@]} -eq 0 ]; then
        log "no active Claude sessions found"
        token="$(read_token)"
        send_telegram "$token" "⏰ 05:00 自动唤醒：未发现任何活跃的 Claude 对话"
        exit 0
    fi

    log "found ${#CLAUDE_TTYS[@]} Claude session(s): ${CLAUDE_TTYS[*]}"

    # ── Inject "继续" into each session ──────────────────────────────────────
    sent_count=0
    fallback_count=0
    failed_ttys=()

    for tty_path in "${CLAUDE_TTYS[@]}"; do
        result="$(inject_continue "$tty_path")"
        case "$result" in
            ok)
                log "sent 继续 (AppleScript) → $tty_path"
                sent_count=$(( sent_count + 1 ))
                ;;
            fallback_ok)
                log "sent 继续 (TTY fallback) → $tty_path"
                sent_count=$(( sent_count + 1 ))
                fallback_count=$(( fallback_count + 1 ))
                ;;
            *)
                log "failed → $tty_path : $result"
                failed_ttys+=("$tty_path")
                ;;
        esac
    done

    # ── Telegram report ───────────────────────────────────────────────────────
    token="$(read_token)"

    local_note=""
    if [[ $fallback_count -gt 0 ]]; then
        local_note="（${fallback_count} 个通过 TTY 直写，屏幕可能已锁定）"
    fi

    if [ ${#failed_ttys[@]} -eq 0 ]; then
        msg="⏰ 05:00 自动唤醒：已向 ${sent_count} 个 Claude 对话发送「继续」${local_note}"
    else
        msg="⏰ 05:00 自动唤醒：${sent_count} 个成功${local_note}，${#failed_ttys[@]} 个失败 (${failed_ttys[*]})"
    fi

    send_telegram "$token" "$msg"
    log "$msg"

} >> "$LOG_FILE" 2>&1
