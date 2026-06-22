#!/usr/bin/env bash
# ============================================================
#  run-loop.sh -- CC 自动滚动开发循环
#  由 run-auto.bat 或 autofish.js 调用，不要直接双击此文件
# ============================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOFISH_ROOT="${AUTOFISH_ROOT:-$SCRIPT_DIR}"
PROJECT_ID="${AUTOFISH_PROJECT_ID:-legacy}"

if [ -n "$AUTOFISH_PROJECT_DIR" ]; then
    PROJECT_DIR="$AUTOFISH_PROJECT_DIR"
else
    PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

if [ -n "$AUTOFISH_STATE_DIR" ]; then
    STATE_DIR="$AUTOFISH_STATE_DIR"
    RUNTIME_DIR="${AUTOFISH_RUNTIME_DIR:-$STATE_DIR/runtime}"
else
    STATE_DIR="$PROJECT_DIR/.asdf"
    RUNTIME_DIR="${AUTOFISH_RUNTIME_DIR:-$STATE_DIR}"
fi

ROOT_CONFIG_FILE="$AUTOFISH_ROOT/config.json"
PROJECT_CONFIG_FILE="${AUTOFISH_PROJECT_CONFIG:-$STATE_DIR/config.json}"
PROJECT_DOC_FILE="${AUTOFISH_PROJECT_DOC:-$STATE_DIR/project.md}"
[ ! -f "$PROJECT_DOC_FILE" ] && [ -f "$PROJECT_DIR/project.md" ] && PROJECT_DOC_FILE="$PROJECT_DIR/project.md"

PROMPT_TEMPLATE_FILE="${AUTOFISH_PROMPT_FILE:-$AUTOFISH_ROOT/auto-prompt.md}"
LOG_FILE="${AUTOFISH_LOG_FILE:-$RUNTIME_DIR/auto-log.txt}"
DONE_FILE="${AUTOFISH_DONE_FILE:-$RUNTIME_DIR/task-done.txt}"
BLOCKED_FILE="${AUTOFISH_BLOCKED_FILE:-$RUNTIME_DIR/task-blocked.txt}"
ROUND_FILE="${AUTOFISH_ROUND_FILE:-$RUNTIME_DIR/auto-round.txt}"
WNTD_FILE="${AUTOFISH_WNTD_FILE:-$RUNTIME_DIR/WhatNeedToDo.md}"

config_val() {
    local key="$1"
    local default="$2"
    local val
    val=$(node -e "
        const fs=require('fs');
        const key=process.argv[1];
        const defaultVal=process.argv[2];
        const files=process.argv.slice(3);
        const keys=key.split('.');
        function read(file){
            try { return JSON.parse(fs.readFileSync(file,'utf8')); }
            catch { return null; }
        }
        function get(obj){
            let v=obj;
            for (const k of keys) v=v&&v[k];
            return v;
        }
        for (const file of files) {
            if (!file) continue;
            const data=read(file);
            const value=data && get(data);
            if (value !== undefined && value !== null && value !== '') {
                process.stdout.write(String(value));
                process.exit(0);
            }
        }
        process.stdout.write(defaultVal);
    " "$key" "$default" "$PROJECT_CONFIG_FILE" "$ROOT_CONFIG_FILE" 2>/dev/null)
    echo "$val"
}

MAX_TURNS=$(config_val "max_turns_per_round" "50")
MAX_BUDGET=$(config_val "max_budget_per_round_usd" "5.00")
MAX_ROUNDS=$(config_val "max_rounds" "200")
SLEEP_SEC=$(config_val "sleep_between_rounds_sec" "5")
STREAM_PROGRESS=$(config_val "display.stream_realtime_progress" "false")

SESSION_ACTIVE=false
SESSION_ROUND_COUNT=0

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

prepare_runtime_files() {
    : > /dev/null
    [ -f "$LOG_FILE" ] || : > "$LOG_FILE"
    [ -f "$DONE_FILE" ] || : > "$DONE_FILE"
    [ -f "$BLOCKED_FILE" ] || : > "$BLOCKED_FILE"
    [ -f "$ROUND_FILE" ] || echo "0" > "$ROUND_FILE"
}

reset_run_state() {
    : > "$LOG_FILE"
    : > "$DONE_FILE"
    : > "$BLOCKED_FILE"
    echo "0" > "$ROUND_FILE"
}

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

build_runtime_context() {
    cat <<EOF
AutoFish runtime context:
- Project id: $PROJECT_ID
- Project root: $PROJECT_DIR
- Project config: $PROJECT_CONFIG_FILE
- Project doc: $PROJECT_DOC_FILE
- Runtime dir: $RUNTIME_DIR
- Done file: $DONE_FILE
- Blocked file: $BLOCKED_FILE
- Log file: $LOG_FILE
- WhatNeedToDo file: $WNTD_FILE
- PROJECT_SPEC.md: $AUTOFISH_ROOT/PROJECT_SPEC.md
Use these exact paths. Do not guess .asdf paths.
EOF
}

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

    local required
    required=$(node -e "
        try {
            const fs=require('fs');
            const files=process.argv.slice(1);
            function read(file){ try { return JSON.parse(fs.readFileSync(file,'utf8')); } catch { return null; } }
            for (const file of files) {
                const data=read(file);
                if (data && data.plugins && Array.isArray(data.plugins.required)) {
                    data.plugins.required.forEach((item)=>console.log(item));
                    process.exit(0);
                }
            }
        } catch {}
    " "$PROJECT_CONFIG_FILE" "$ROOT_CONFIG_FILE" 2>/dev/null)

    for plugin in $required; do
        [ -z "$plugin" ] && continue
        if ! check_single_plugin "$plugin"; then
            log "[FATAL] Required plugin '$plugin' not installed"
            return 1
        fi
        log "[PLUGIN] $plugin: installed (required)"
    done

    local optional
    optional=$(node -e "
        try {
            const fs=require('fs');
            const files=process.argv.slice(1);
            function read(file){ try { return JSON.parse(fs.readFileSync(file,'utf8')); } catch { return null; } }
            for (const file of files) {
                const data=read(file);
                if (data && data.plugins && Array.isArray(data.plugins.optional)) {
                    data.plugins.optional.forEach((item)=>console.log(item));
                    process.exit(0);
                }
            }
        } catch {}
    " "$PROJECT_CONFIG_FILE" "$ROOT_CONFIG_FILE" 2>/dev/null)

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

validate_project_doc() {
    local enabled
    enabled=$(config_val "project_validation.enabled" "true")
    [ "$enabled" != "true" ] && return 0

    if [ ! -f "$PROJECT_DOC_FILE" ]; then
        log "[FATAL] project.md not found at $PROJECT_DOC_FILE"
        log "  Create project.md with required sections and - [ ] tasks"
        return 1
    fi

    local sections
    sections=$(node -e "
        try {
            const fs=require('fs');
            const files=process.argv.slice(1);
            function read(file){ try { return JSON.parse(fs.readFileSync(file,'utf8')); } catch { return null; } }
            for (const file of files) {
                const data=read(file);
                const sections=data?.project_validation?.required_sections;
                if (Array.isArray(sections) && sections.length) {
                    sections.forEach((item)=>console.log(item));
                    process.exit(0);
                }
            }
        } catch {}
        console.log('技术栈');
        console.log('任务清单');
    " "$PROJECT_CONFIG_FILE" "$ROOT_CONFIG_FILE" 2>/dev/null)

    local missing_sections=""
    while IFS= read -r section; do
        [ -z "$section" ] && continue
        if ! grep -q "^## $section" "$PROJECT_DOC_FILE" 2>/dev/null; then
            missing_sections="$missing_sections  $section"
        fi
    done <<< "$sections"

    if [ -n "$missing_sections" ]; then
        log "[FATAL] project.md missing required sections:$missing_sections"
        return 1
    fi

    local task_format
    task_format=$(config_val "project_validation.task_format" "- [ ]")
    if ! grep -qF -e "$task_format" "$PROJECT_DOC_FILE"; then
        log "[FATAL] No tasks found in project.md (format: '$task_format')"
        return 1
    fi

    log "project.md validation: PASSED"
    return 0
}

validate_bootstrap_confirmation() {
    local status
    status=$(config_val "bootstrap.status" "not_started")
    local confirmed
    confirmed=$(config_val "bootstrap.project_doc_confirmed" "false")
    local config_decision
    config_decision=$(config_val "bootstrap.config_decision" "pending")

    if [ "$status" != "confirmed" ] || [ "$confirmed" != "true" ] || [ "$config_decision" = "pending" ]; then
        log "[FATAL] Project bootstrap not confirmed"
        log "  Project config: $PROJECT_CONFIG_FILE"
        log "  Project doc:    $PROJECT_DOC_FILE"
        log "  Bootstrap:      status=$status, confirmed=$confirmed, config_decision=$config_decision"
        log "  Finish bootstrap Q&A in AutoFish before starting run-loop"
        return 1
    fi

    log "bootstrap confirmation: PASSED"
    return 0
}

check_safety() {
    if ! git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        log "[FATAL] git project not found at $PROJECT_DIR"
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
    if [ ! -f "$PROMPT_TEMPLATE_FILE" ]; then
        log "[FATAL] auto-prompt.md not found at $PROMPT_TEMPLATE_FILE"
        return 1
    fi
    if ! validate_bootstrap_confirmation; then
        return 1
    fi
    if ! validate_project_doc; then
        return 1
    fi
    return 0
}

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

make_round_checkpoint() {
    local round="$1"
    local enabled
    enabled=$(config_val "git_checkpoint.enabled" "true")
    [ "$enabled" != "true" ] && return 0

    local interval
    interval=$(config_val "git_checkpoint.interval_rounds" "1")
    if [ "$((round % interval))" -ne 0 ] && [ "$round" -ne 1 ]; then
        return 0
    fi

    local msg=""
    if [ -f "$DONE_FILE" ]; then
        local latest
        latest=$(tail -3 "$DONE_FILE" 2>/dev/null | grep -oP '\]\s+\K.+?(?=\s*—|\s*$)' 2>/dev/null || \
                 tail -3 "$DONE_FILE" 2>/dev/null | sed 's/.*\] //; s/ —.*//; s/PROGRESS: //; s/SESSION_RESET//')
        if [ -n "$latest" ]; then
            msg=$(echo "$latest" | tr '\n' ';' | sed 's/;$//; s/;/, /g')
        fi
    fi

    [ -z "$msg" ] && msg="round $round checkpoint"
    msg="autofish(r$round): $msg"

    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "$msg" 2>/dev/null || true
        log "Git checkpoint(r$round): $msg"
    fi
}

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

check_context_ratio() {
    local threshold
    threshold=$(config_val "session.rebuild_strategy.context_ratio_threshold" "")
    [ -z "$threshold" ] && return 1

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

run_cc_round() {
    local round="$1"
    local tmp_log
    tmp_log=$(mktemp)
    local tmp_err
    tmp_err=$(mktemp)

    log_sep
    log "Round $round"
    log "  Session mode: $([ "$SESSION_ACTIVE" = true ] && echo continue || echo fresh)"
    log "  Prompt file:  $PROMPT_TEMPLATE_FILE"
    log "  Stream mode:  $STREAM_PROGRESS"
    log "  Limits:       turns=$MAX_TURNS budget=\$$MAX_BUDGET"

    local exit_code=0
    local prompt_text
    prompt_text="$(build_runtime_context)

$(cat "$PROMPT_TEMPLATE_FILE")"
    log "Prompt: ${#prompt_text} chars from $PROMPT_TEMPLATE_FILE"

    local continue_flag=""
    if [ "$SESSION_ACTIVE" = true ]; then
        continue_flag="--continue"
        log "Round $round: continuing previous session"
    else
        log "Round $round: starting fresh session"
    fi

    local cache_flag="--exclude-dynamic-system-prompt-sections"
    local progress_filter="$AUTOFISH_ROOT/progress-filter.js"

    if [ "$STREAM_PROGRESS" = true ] && [ -f "$progress_filter" ]; then
        log "Mode: stream (filter: $progress_filter)"
        claude -p "$prompt_text" \
            $continue_flag \
            $cache_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            --verbose \
            --output-format stream-json \
            --include-partial-messages \
            2>"$tmp_err" | node "$progress_filter" 2>/dev/null | tee -a "$LOG_FILE" \
            || exit_code=$?
    else
        log "Mode: text (stream=$STREAM_PROGRESS, filter_exists=$([ -f "$progress_filter" ] && echo yes || echo no))"
        local spin_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        local spin_idx=0
        local start_ts
        start_ts=$(date +%s)

        claude -p "$prompt_text" \
            $continue_flag \
            $cache_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            > "$tmp_log" 2>"$tmp_err" &
        local cc_pid=$!
        log "CC PID: $cc_pid"

        while kill -0 $cc_pid 2>/dev/null; do
            local now_ts
            now_ts=$(date +%s)
            local elapsed=$((now_ts - start_ts))
            local min=$((elapsed / 60))
            local sec=$((elapsed % 60))
            local spin="${spin_chars:$spin_idx:1}"
            spin_idx=$(( (spin_idx + 1) % ${#spin_chars} ))
            printf "\r  %s [%02d:%02d] CC 工作中..." "$spin" "$min" "$sec"
            sleep 0.3
        done
        printf "\r\x1b[K"

        wait $cc_pid || exit_code=$?

        cat "$tmp_log" >> "$LOG_FILE"
        cat "$tmp_log"
    fi

    if [ "$exit_code" -ne 0 ]; then
        local err_size
        err_size=$(wc -c < "$tmp_err" 2>/dev/null | tr -d '[:space:]')
        log "CC stderr (${err_size:-0} bytes): $(head -3 "$tmp_err" 2>/dev/null | tr '\n' ' ')"
        local out_size
        out_size=$(wc -c < "$tmp_log" 2>/dev/null | tr -d '[:space:]')
        log "CC stdout (${out_size:-0} bytes)"
    fi

    rm -f "$tmp_log" "$tmp_err"

    log "Round $round end (exit=$exit_code)"
    return $exit_code
}

generate_what_need_to_do() {
    log "Generating WhatNeedToDo.md (checklist format)..."

    local summary_prompt
    summary_prompt=$(cat <<EOF
你是一个项目状态总结助手。AutoFish 在自动执行过程中遇到了阻塞，需要你来分析并生成一份交互式处理指南。

关键文件路径：
- 项目文档：$PROJECT_DOC_FILE
- 已完成任务：$DONE_FILE
- 阻塞任务：$BLOCKED_FILE
- 运行日志：$LOG_FILE
- 输出文件：$WNTD_FILE

要求：
1. 阅读上面列出的文件。
2. 使用 Write 工具创建 `$WNTD_FILE`。
3. 每个阻塞项必须使用 `- [ ]` checkbox。
4. 每项下必须包含：
   - 阻塞原因
   - 你需要做什么
   - 用户反馈
5. 文档需包含：
   - 阻塞概览
   - 阻塞任务清单
   - 已完成任务
   - 待执行任务
   - 用户反馈区
6. 中文，具体，可操作。
EOF
)

    claude -p "$summary_prompt" \
        --permission-mode auto \
        --max-turns 15 \
        --max-budget-usd 0.50 \
        2>&1 | tee -a "$LOG_FILE" || true

    if [ -f "$WNTD_FILE" ]; then
        log "WhatNeedToDo.md generated: $WNTD_FILE"
    else
        log "[WARN] CC did not create WhatNeedToDo.md, generating fallback..."
        cat > "$WNTD_FILE" <<EOF
# AutoFish 阻塞处理指南

> 生成时间：$(date '+%Y-%m-%d %H:%M')
> 处理状态：待处理

## 阻塞任务清单

$(while IFS= read -r line; do [ -n "$line" ] && echo "- [ ] $line"; done < "$BLOCKED_FILE" 2>/dev/null)

## 已完成任务

$(cat "$DONE_FILE" 2>/dev/null || echo "无记录")

## 处理完成后

重新运行 AutoFish。脚本会自动检测阻塞是否已解决。
EOF
        log "Fallback WhatNeedToDo.md created"
    fi
}

update_what_need_to_do() {
    log "Updating WhatNeedToDo.md (preserving user input)..."

    local update_prompt
    update_prompt=$(cat <<EOF
你是一个项目状态更新助手。用户已处理部分阻塞项，请增量更新文档。

关键文件路径：
- WhatNeedToDo：$WNTD_FILE
- 阻塞任务：$BLOCKED_FILE
- 项目文档：$PROJECT_DOC_FILE

原则：
1. 保留所有用户已写内容。
2. 只更新仍然需要处理的阻塞项。
3. 如果某项已通过用户反馈解决，可改成 `- [x]`。
4. 如果有新阻塞，可追加新项。
5. 不要重写整个文档。
EOF
)

    claude -p "$update_prompt" \
        --permission-mode auto \
        --max-turns 15 \
        --max-budget-usd 0.50 \
        2>&1 | tee -a "$LOG_FILE" || true

    log "WhatNeedToDo.md updated"
}

handle_what_need_to_do() {
    if [ ! -f "$WNTD_FILE" ]; then
        return 0
    fi

    log "Found existing WhatNeedToDo.md, analyzing user interaction..."

    local section
    section=$(sed -n '/^## 阻塞任务清单/,/^## /p' "$WNTD_FILE" 2>/dev/null)

    local unresolved
    unresolved=$(echo "$section" | grep -c "^- \[ \]" 2>/dev/null | tr -d '\r\n' || echo 0)
    local resolved
    resolved=$(echo "$section" | grep -c "^- \[x\]" 2>/dev/null | tr -d '\r\n' || echo 0)

    log "Blocked items in WNTD: $resolved resolved, $unresolved remaining"

    if [ "$unresolved" -eq 0 ] && [ "$resolved" -gt 0 ]; then
        log "All blocked items resolved by user, continuing execution..."
        rm -f "$WNTD_FILE"
        return 0
    fi

    if [ "$resolved" -gt 0 ]; then
        log "User resolved $resolved item(s), updating document via CC..."
        update_what_need_to_do

        local new_section
        new_section=$(sed -n '/^## 阻塞任务清单/,/^## /p' "$WNTD_FILE" 2>/dev/null)
        local new_unresolved
        new_unresolved=$(echo "$new_section" | grep -c "^- \[ \]" 2>/dev/null | tr -d '\r\n' || echo 0)

        if [ "$new_unresolved" -eq 0 ]; then
            log "CC resolved all remaining items during update, continuing..."
            rm -f "$WNTD_FILE"
            return 0
        fi

        log "Still $new_unresolved item(s) need human review. See: $WNTD_FILE"
        exit 0
    fi

    local has_blocked=false
    if [ -f "$BLOCKED_FILE" ] && [ -s "$BLOCKED_FILE" ]; then
        local blocked_items
        blocked_items=$(grep -cv "ALL_BLOCKED" "$BLOCKED_FILE" 2>/dev/null | tr -d '\r\n' || echo 0)
        if [ "$blocked_items" -gt 0 ] 2>/dev/null; then
            has_blocked=true
        fi
    fi

    if $has_blocked; then
        log "Blocks present and WNTD not yet reviewed by user."
        log "Edit: $WNTD_FILE (mark resolved as - [x], add notes), then restart."
        exit 0
    else
        log "WNTD exists but no active blocked entries found. Keep file for manual review: $WNTD_FILE"
        exit 0
    fi
}

main() {
    prepare_runtime_files
    handle_what_need_to_do
    reset_run_state

    log_sep
    log "Run summary"
    log "  Project id:   $PROJECT_ID"
    log "  Project root: $PROJECT_DIR"
    log "  Project doc:  $PROJECT_DOC_FILE"
    log "  Config:       $PROJECT_CONFIG_FILE"
    log "  Runtime dir:  $RUNTIME_DIR"
    log "  Limits:       turns=$MAX_TURNS budget=\$$MAX_BUDGET rounds=$MAX_ROUNDS sleep=${SLEEP_SEC}s"
    log_sep

    if ! check_safety; then
        log "[FATAL] Safety check failed, aborting"
        exit 1
    fi

    make_checkpoint

    local START_TIMESTAMP
    START_TIMESTAMP=$(date +%s)
    local MAX_DURATION_MIN
    MAX_DURATION_MIN=$(config_val "runtime.max_duration_minutes" "")
    local STOP_AT
    STOP_AT=$(config_val "runtime.stop_at" "")

    local round=1
    local last_done_lines=0
    local stale_count=0
    local stop_reason="CONTINUE"

    while true; do
        echo "$round" > "$ROUND_FILE"

        if should_rebuild_session; then
            log "Session rebuild triggered"
            SESSION_ACTIVE=false
            SESSION_ROUND_COUNT=0
            sed -i '/SESSION_RESET/d' "$DONE_FILE" 2>/dev/null || true
        fi

        local round_exit=0
        if run_cc_round "$round"; then
            round_exit=0
        else
            round_exit=$?
        fi

        make_round_checkpoint "$round"

        if [ "$round_exit" -eq 0 ]; then
            SESSION_ACTIVE=true
            SESSION_ROUND_COUNT=$((SESSION_ROUND_COUNT + 1))
        else
            log "Round $round failed (exit=$round_exit), will start fresh next round"
            SESSION_ACTIVE=false
            SESSION_ROUND_COUNT=0
        fi

        stop_reason=$(check_stop_conditions "$round")

        case "$stop_reason" in
            ALL_COMPLETE)
                log ">>> All tasks complete!"
                break
                ;;
            ALL_BLOCKED)
                log ">>> All remaining tasks blocked, human review needed"
                generate_what_need_to_do
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
                local delta=$((current_done_lines - last_done_lines))

                if [ "$current_done_lines" -gt "$last_done_lines" ]; then
                    stale_count=0
                    log "Round summary: done_delta=$delta stale_streak=$stale_count next=continue"
                    last_done_lines=$current_done_lines
                else
                    stale_count=$((stale_count + 1))
                    log "Round summary: done_delta=0 stale_streak=$stale_count next=continue"
                fi

                if [ "$stale_count" -ge 5 ]; then
                    log ">>> ${stale_count} rounds with no progress, stopping"
                    echo "ALL_BLOCKED" >> "$BLOCKED_FILE"
                    generate_what_need_to_do
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
    echo "=== Summary ==="
    echo "Project id:   $PROJECT_ID"
    echo "Project doc:  $PROJECT_DOC_FILE"
    echo "Runtime dir:  $RUNTIME_DIR"
    echo "Total rounds: $round"
    echo "Stop reason:  $stop_reason"
    echo ""
    echo "=== Files ==="
    echo "Done:         $DONE_FILE"
    echo "Blocked:      $BLOCKED_FILE"
    echo "Log:          $LOG_FILE"
    echo ""
    echo "=== Next actions ==="
    echo "Review files above."
    echo "Rollback: git log --oneline | grep 'pre-autonomous'"
    echo ""
}

main "$@"
