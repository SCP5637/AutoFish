#!/usr/bin/env bash
# ============================================================
#  run-loop.sh -- CC 自动滚动开发循环
#  由 run-auto.bat 调用，不要直接双击此文件
# ============================================================

set -eo pipefail

# Auto-detect project directory (script is in .asdf/, project is parent)
# Override by setting AUTOFISH_PROJECT_DIR environment variable
if [ -n "$AUTOFISH_PROJECT_DIR" ]; then
    PROJECT_DIR="$AUTOFISH_PROJECT_DIR"
else
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
PROMPT_FILE="$PROJECT_DIR/.asdf/auto-prompt.md"
LOG_FILE="$PROJECT_DIR/.asdf/auto-log.txt"
DONE_FILE="$PROJECT_DIR/.asdf/task-done.txt"
BLOCKED_FILE="$PROJECT_DIR/.asdf/task-blocked.txt"
ROUND_FILE="$PROJECT_DIR/.asdf/auto-round.txt"

MAX_TURNS=50
MAX_BUDGET=5.00
MAX_ROUNDS=200
SLEEP_SEC=5

cd "$PROJECT_DIR"

# init
echo "" > "$LOG_FILE"
echo "" > "$DONE_FILE"
echo "" > "$BLOCKED_FILE"
echo "0" > "$ROUND_FILE"

log() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_sep() {
    local sep="============================================================"
    echo "$sep"
    echo "$sep" >> "$LOG_FILE"
}

# ========== safety checks ==========
check_safety() {
    if [ ! -d "$PROJECT_DIR/.git" ]; then
        log "[FATAL] .git not found"
        return 1
    fi
    if ! command -v claude &>/dev/null; then
        log "[FATAL] claude command not found"
        return 1
    fi
    if [ ! -f "$PROMPT_FILE" ]; then
        log "[FATAL] auto-prompt.md not found"
        return 1
    fi
    return 0
}

# ========== git checkpoint ==========
make_checkpoint() {
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        local ts
        ts=$(date '+%Y%m%d-%H%M%S')
        git commit -m "checkpoint: pre-autonomous $ts" 2>/dev/null || true
        log "Git checkpoint: $ts"
    else
        log "No uncommitted changes, skip checkpoint"
    fi
}

# ========== stop conditions ==========
check_stop_conditions() {
    local round="$1"

    if grep -q "ALL_COMPLETE" "$DONE_FILE" 2>/dev/null; then
        echo "ALL_COMPLETE"
        return
    fi

    if grep -q "ALL_BLOCKED" "$BLOCKED_FILE" 2>/dev/null; then
        echo "ALL_BLOCKED"
        return
    fi

    if [ "$round" -ge "$MAX_ROUNDS" ]; then
        echo "MAX_ROUNDS"
        return
    fi

    echo "CONTINUE"
}

# ========== run one CC round ==========
run_cc_round() {
    local round="$1"
    local tmp_log
    tmp_log=$(mktemp)

    log_sep
    log "Round $round start"

    local exit_code=0

    local prompt_text
    prompt_text=$(cat "$PROMPT_FILE")

    # Run CC, capture output to temp file + show on screen
    claude -p "$prompt_text" \
        --permission-mode auto \
        --max-turns "$MAX_TURNS" \
        --max-budget-usd "$MAX_BUDGET" \
        > "$tmp_log" 2>&1 || exit_code=$?

    # Append to log file and display
    cat "$tmp_log" >> "$LOG_FILE"
    cat "$tmp_log"
    rm -f "$tmp_log"

    log "Round $round end (exit=$exit_code)"
    return $exit_code
}

# ========== main ==========
main() {
    log_sep
    log "Autonomous dev loop started"
    log "Project: $PROJECT_DIR"
    log "Permission: auto | Max turns/round: $MAX_TURNS | Max budget/round: \$$MAX_BUDGET"
    log "Max rounds: $MAX_ROUNDS | Sleep between rounds: ${SLEEP_SEC}s"
    log_sep

    if ! check_safety; then
        log "[FATAL] Safety check failed, aborting"
        exit 1
    fi

    make_checkpoint

    local round=1
    local last_done_lines=0
    local stale_count=0

    while true; do
        echo "$round" > "$ROUND_FILE"

        run_cc_round "$round" || true

        local stop_reason
        stop_reason=$(check_stop_conditions "$round")

        case "$stop_reason" in
            ALL_COMPLETE)
                log ">>> All tasks complete!"
                break
                ;;
            ALL_BLOCKED)
                log ">>> All remaining tasks blocked, human review needed"
                break
                ;;
            MAX_ROUNDS)
                log ">>> Max rounds reached ($MAX_ROUNDS)"
                break
                ;;
            CONTINUE)
                local current_done_lines=0
                [ -f "$DONE_FILE" ] && current_done_lines=$(wc -l < "$DONE_FILE" 2>/dev/null || echo 0)

                if [ "$current_done_lines" -gt "$last_done_lines" ]; then
                    stale_count=0
                    log "Progress: $((current_done_lines - last_done_lines)) task(s) done this round"
                    last_done_lines=$current_done_lines
                else
                    stale_count=$((stale_count + 1))
                    log "No progress this round (stale streak: ${stale_count})"
                fi

                if [ "$stale_count" -ge 5 ]; then
                    log ">>> ${stale_count} rounds with no progress, stopping"
                    echo "ALL_BLOCKED" >> "$BLOCKED_FILE"
                    break
                fi
                ;;
        esac

        round=$((round + 1))
        log "Sleeping ${SLEEP_SEC}s..."
        sleep "$SLEEP_SEC"
    done

    log_sep
    log "Autonomous dev loop ended"
    log "Total rounds: $round | Reason: $stop_reason"
    log_sep

    echo ""
    echo "=== Results ==="
    echo "  Done tasks:    cat $DONE_FILE"
    echo "  Blocked tasks: cat $BLOCKED_FILE"
    echo "  Full log:      cat $LOG_FILE"
    echo ""
    echo "To rollback: git log --oneline | grep 'pre-autonomous'"
    echo ""
}

main "$@"
