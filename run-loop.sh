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
CONFIG_FILE="$PROJECT_DIR/.asdf/config.json"

# Read a value from config.json, fallback to default
config_val() {
    local key="$1"
    local default="$2"
    local val
    val=$(node -e "
        try {
            const c=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
            const keys='$key'.split('.');
            let v=c;
            for(const k of keys) v=v&&v[k];
            process.stdout.write(v!=null&&v!==''?String(v):'$default');
        } catch(e) { process.stdout.write('$default'); }
    " "$CONFIG_FILE" 2>/dev/null)
    echo "$val"
}

# Override PROJECT_DIR from config if set to non-default value
_config_dir=$(config_val "project_dir" "./")
if [ "$_config_dir" != "./" ] && [ -n "$_config_dir" ]; then
    PROJECT_DIR="$(cd "$_config_dir" && pwd)"
    CONFIG_FILE="$PROJECT_DIR/.asdf/config.json"
fi

PROMPT_FILE="$PROJECT_DIR/.asdf/auto-prompt.md"
LOG_FILE="$PROJECT_DIR/.asdf/auto-log.txt"
DONE_FILE="$PROJECT_DIR/.asdf/task-done.txt"
BLOCKED_FILE="$PROJECT_DIR/.asdf/task-blocked.txt"
ROUND_FILE="$PROJECT_DIR/.asdf/auto-round.txt"

MAX_TURNS=$(config_val "max_turns_per_round" "50")
MAX_BUDGET=$(config_val "max_budget_per_round_usd" "5.00")
MAX_ROUNDS=$(config_val "max_rounds" "200")
SLEEP_SEC=$(config_val "sleep_between_rounds_sec" "5")
STREAM_PROGRESS=$(config_val "display.stream_realtime_progress" "true")

# Session state
SESSION_ACTIVE=false
SESSION_ROUND_COUNT=0

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

# ========== plugin checks ==========
check_single_plugin() {
    local plugin="$1"
    case "$plugin" in
        cc-safe-setup)
            local hooks_dir="$HOME/.claude/hooks"
            if [ -d "$hooks_dir" ]; then
                local hook_count
                hook_count=$(ls "$hooks_dir"/*.sh 2>/dev/null | wc -l)
                if [ "$hook_count" -ge 4 ]; then
                    return 0
                fi
            fi
            return 1
            ;;
        *)
            if command -v "$plugin" &>/dev/null; then
                return 0
            fi
            if npm list -g "$plugin" &>/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
    esac
}

check_plugins() {
    local check_enabled
    check_enabled=$(config_val "plugins.check_on_startup" "true")
    [ "$check_enabled" != "true" ] && return 0

    # Check required plugins (missing = fatal)
    local required
    required=$(node -e "
        try{JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'))
            .plugins.required.forEach(function(p){console.log(p)});
        }catch(e){}" 2>/dev/null)

    for plugin in $required; do
        [ -z "$plugin" ] && continue
        if ! check_single_plugin "$plugin"; then
            log "[FATAL] Required plugin '$plugin' not installed"
            return 1
        fi
        log "[PLUGIN] $plugin: installed (required)"
    done

    # Check optional plugins (missing = warning)
    local optional
    optional=$(node -e "
        try{JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'))
            .plugins.optional.forEach(function(p){console.log(p)});
        }catch(e){}" 2>/dev/null)

    for plugin in $optional; do
        [ -z "$plugin" ] && continue
        if check_single_plugin "$plugin"; then
            log "[PLUGIN] $plugin: installed (optional)"
        else
            log "[WARN] Optional plugin '$plugin' not installed"

            local auto_install
            auto_install=$(config_val "plugins.auto_install_missing" "false")
            if [ "$auto_install" = "true" ]; then
                log "  Auto-installing: npm install -g $plugin..."
                npm install -g "$plugin" 2>&1 || log "[WARN] Auto-install of $plugin failed"
            fi
        fi
    done

    return 0
}

# ========== safety checks ==========
check_safety() {
    if [ ! -d "$PROJECT_DIR/.git" ]; then
        log "[FATAL] .git not found"
        return 1
    fi
    if ! command -v claude &>/dev/null; then
        log "[FATAL] claude command not found. Install: npm install -g @anthropic-ai/claude-code"
        return 1
    fi
    local cc_version
    cc_version=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log "Claude Code version: ${cc_version:-unknown}"
    if ! check_plugins; then
        return 1
    fi
    if [ ! -f "$PROMPT_FILE" ]; then
        log "[FATAL] auto-prompt.md not found"
        return 1
    fi
    if ! validate_project_doc; then
        return 1
    fi
    return 0
}

# ========== project.md validation ==========
validate_project_doc() {
    local enabled
    enabled=$(config_val "project_validation.enabled" "true")
    [ "$enabled" != "true" ] && return 0

    # Find project.md: try .asdf/ first, then root
    local doc_file="${PROJECT_DIR}/.asdf/project.md"
    [ ! -f "$doc_file" ] && doc_file="${PROJECT_DIR}/project.md"

    if [ ! -f "$doc_file" ]; then
        log "[FATAL] project.md not found at ${PROJECT_DIR}/.asdf/project.md or ${PROJECT_DIR}/project.md"
        log "  Create .asdf/project.md with required sections and - [ ] tasks"
        return 1
    fi

    # Check required sections
    local sections
    sections=$(node -e "
        try{const c=JSON.parse(require('fs').readFileSync('$CONFIG_FILE','utf8'));
        const s=c.project_validation?.required_sections||['技术栈','任务清单'];
        s.forEach(function(x){console.log(x)});}catch(e){console.log('技术栈');console.log('任务清单');}" 2>/dev/null)

    local missing_sections=""
    while IFS= read -r section; do
        [ -z "$section" ] && continue
        if ! grep -q "^## $section" "$doc_file" 2>/dev/null; then
            missing_sections="$missing_sections  $section"
        fi
    done <<< "$sections"

    if [ -n "$missing_sections" ]; then
        log "[FATAL] project.md missing required sections:$missing_sections"
        return 1
    fi

    # Check task format
    local task_format
    task_format=$(config_val "project_validation.task_format" "- [ ]")
    if ! grep -qF "$task_format" "$doc_file"; then
        log "[FATAL] No tasks found in project.md (format: '$task_format')"
        return 1
    fi

    log "project.md validation: PASSED"
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

    # Check runtime limits
    local runtime_result
    runtime_result=$(check_runtime_limit)
    case "$runtime_result" in
        RUNTIME_LIMIT|STOP_TIME)
            echo "$runtime_result"
            return
            ;;
    esac

    echo "CONTINUE"
}

# ========== runtime limit ==========
check_runtime_limit() {
    if [ -n "$MAX_DURATION_MIN" ]; then
        local now
        now=$(date +%s)
        local elapsed=$(( (now - START_TIMESTAMP) / 60 ))
        if [ "$elapsed" -ge "$MAX_DURATION_MIN" ]; then
            log "Runtime limit reached: ${elapsed}min >= ${MAX_DURATION_MIN}min"
            echo "RUNTIME_LIMIT"
            return
        fi
    fi

    if [ -n "$STOP_AT" ]; then
        local now_time
        now_time=$(date +%H:%M)
        if [[ "$now_time" > "$STOP_AT" ]] || [ "$now_time" = "$STOP_AT" ]; then
            log "Stop time reached: $now_time >= $STOP_AT"
            echo "STOP_TIME"
            return
        fi
    fi

    echo "CONTINUE"
}

# ========== session rebuild helpers ==========
check_context_ratio() {
    local threshold
    threshold=$(config_val "session.rebuild_strategy.context_ratio_threshold" "")
    [ -z "$threshold" ] && return 1

    # Estimate: accumulated turns vs safe threshold for 200K context window
    local accumulated_turns=$((SESSION_ROUND_COUNT * MAX_TURNS))
    local safe_turns_by_ratio
    safe_turns_by_ratio=$(node -e "console.log(Math.floor(250 * $threshold))" 2>/dev/null || echo "160")

    if [ "$accumulated_turns" -ge "$safe_turns_by_ratio" ]; then
        log "Context ratio: accumulated $accumulated_turns turns >= threshold $safe_turns_by_ratio"
        return 0
    fi
    return 1
}

should_rebuild_session() {
    local mode
    mode=$(config_val "session.rebuild_strategy.mode" "any")

    local cond_rounds=false
    local cond_context=false
    local cond_marker=false

    local every_n
    every_n=$(config_val "session.rebuild_strategy.every_n_rounds" "")
    if [ -n "$every_n" ] && [ "$SESSION_ROUND_COUNT" -ge "$every_n" ]; then
        cond_rounds=true
    fi

    if check_context_ratio; then
        cond_context=true
    fi

    local respect_markers
    respect_markers=$(config_val "session.rebuild_strategy.respect_task_markers" "true")
    if [ "$respect_markers" = "true" ] && grep -q "SESSION_RESET" "$DONE_FILE" 2>/dev/null; then
        cond_marker=true
    fi

    case "$mode" in
        all)
            # All enabled conditions must be satisfied; disabled conditions are skipped
            local any_enabled=false
            [ -n "$every_n" ] && any_enabled=true
            local ratio_thresh
            ratio_thresh=$(config_val "session.rebuild_strategy.context_ratio_threshold" "")
            [ -n "$ratio_thresh" ] && any_enabled=true
            [ "$respect_markers" = "true" ] && any_enabled=true

            if $any_enabled; then
                local all_met=true
                [ -z "$every_n" ] || $cond_rounds || all_met=false
                [ -z "$ratio_thresh" ] || $cond_context || all_met=false
                [ "$respect_markers" != "true" ] || $cond_marker || all_met=false
                if $all_met; then return 0; fi
            fi
            ;;
        any|*)
            if $cond_rounds || $cond_context || $cond_marker; then
                return 0
            fi
            ;;
    esac
    return 1
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

    local continue_flag=""
    if [ "$SESSION_ACTIVE" = true ]; then
        continue_flag="--continue"
        log "Round $round: continuing previous session"
    else
        log "Round $round: starting fresh session"
    fi

    # Run CC with appropriate output mode
    if [ "$STREAM_PROGRESS" = true ]; then
        claude -p "$prompt_text" \
            $continue_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            --output-format stream-json \
            --include-partial-messages \
            --verbose \
            2>&1 | tee -a "$LOG_FILE" \
            || exit_code=$?
    else
        claude -p "$prompt_text" \
            $continue_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            > "$tmp_log" 2>&1 || exit_code=$?

        cat "$tmp_log" >> "$LOG_FILE"
        cat "$tmp_log"
    fi
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
    log "Max rounds: $MAX_ROUNDS | Sleep: ${SLEEP_SEC}s | Duration limit: ${MAX_DURATION_MIN:-none} | Stop at: ${STOP_AT:-none}"
    log_sep

    if ! check_safety; then
        log "[FATAL] Safety check failed, aborting"
        exit 1
    fi

    make_checkpoint

    # Runtime limit tracking
    local START_TIMESTAMP
    START_TIMESTAMP=$(date +%s)
    local MAX_DURATION_MIN
    MAX_DURATION_MIN=$(config_val "runtime.max_duration_minutes" "")
    local STOP_AT
    STOP_AT=$(config_val "runtime.stop_at" "")

    local round=1
    local last_done_lines=0
    local stale_count=0

    while true; do
        echo "$round" > "$ROUND_FILE"

        # Check for session rebuild before starting round
        if should_rebuild_session; then
            log "Session rebuild triggered"
            SESSION_ACTIVE=false
            SESSION_ROUND_COUNT=0
            # Clean up SESSION_RESET marker so it doesn't re-trigger
            sed -i '/SESSION_RESET/d' "$DONE_FILE" 2>/dev/null || true
        fi

        run_cc_round "$round" || true

        SESSION_ACTIVE=true
        SESSION_ROUND_COUNT=$((SESSION_ROUND_COUNT + 1))

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
            RUNTIME_LIMIT)
                log ">>> Runtime limit reached"
                break
                ;;
            STOP_TIME)
                log ">>> Stop time reached"
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
