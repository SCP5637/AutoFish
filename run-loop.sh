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
STOP_FILE="${AUTOFISH_STOP_FILE:-$RUNTIME_DIR/stop-requested}"

GIT_AVAILABLE=false
GIT_ROOT=""
CHECKPOINT_MODE="auto"
CURRENT_CC_PID=""
STOP_REASON=""
NO_COLOR_MODE="${NO_COLOR:-}"

c_reset="\033[0m"
c_note="\033[90m"
c_run="\033[33m"
c_key="\033[96m"
c_warn="\033[93m"
c_error="\033[91m"

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
STREAM_PROGRESS=$(config_val "display.stream_realtime_progress" "true")
CHECKPOINT_MODE=$(config_val "checkpoint.mode" "auto")

SESSION_ACTIVE=false
SESSION_ROUND_COUNT=0

mkdir -p "$RUNTIME_DIR"
cd "$PROJECT_DIR"

colorize() {
    local color="$1"
    shift
    local text="$*"
    if [ -n "$NO_COLOR_MODE" ] || [ ! -t 1 ]; then
        printf '%s' "$text"
        return
    fi
    printf '%b%s%b' "$color" "$text" "$c_reset"
}

log_plain() {
    local msg="[$(date '+%H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
}

log_colored() {
    local color="$1"
    shift
    local msg="[$(date '+%H:%M:%S')] $*"
    colorize "$color" "$msg"
    printf '\n'
    echo "$msg" >> "$LOG_FILE"
}

log_note() { log_colored "$c_note" "$@"; }
log_run() { log_colored "$c_run" "$@"; }
log_key() { log_colored "$c_key" "$@"; }
log_warn() { log_colored "$c_warn" "$@"; }
log_error() { log_colored "$c_error" "$@"; }
log() { log_note "$@"; }

log_sep() {
    local sep="============================================================"
    if [ -n "$NO_COLOR_MODE" ] || [ ! -t 1 ]; then
        echo "$sep"
    else
        colorize "$c_key" "$sep"
        printf '\n'
    fi
    echo "$sep" >> "$LOG_FILE"
}

prepare_runtime_files() {
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
    rm -f "$STOP_FILE" 2>/dev/null || true
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
Use these exact paths. Do not guess old default paths.
EOF
}

init_git_state() {
    if git -C "$PROJECT_DIR" rev-parse --show-toplevel >/dev/null 2>&1; then
        GIT_AVAILABLE=true
        GIT_ROOT=$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null | tr -d '\r\n')
        log_key "Git mode: available ($GIT_ROOT)"
    else
        GIT_AVAILABLE=false
        GIT_ROOT=""
        log_warn "Git mode: unavailable -> checkpoint fallback active"
    fi
}

plugin_list() {
    local key="$1"
    node -e "
        try {
            const fs=require('fs');
            const files=process.argv.slice(2);
            const key=process.argv[1];
            function read(file){ try { return JSON.parse(fs.readFileSync(file,'utf8')); } catch { return null; } }
            for (const file of files) {
                const data=read(file);
                const arr=data?.plugins?.[key];
                if (Array.isArray(arr)) {
                    arr.forEach((item)=>console.log(item));
                    process.exit(0);
                }
            }
        } catch {}
    " "$key" "$PROJECT_CONFIG_FILE" "$ROOT_CONFIG_FILE" 2>/dev/null
}

safe_setup_detail() {
    node -e "
        const fs=require('fs');
        const os=require('os');
        const path=require('path');
        const hooksDir=path.join(os.homedir(), '.claude', 'hooks');
        const settingsFiles=[
          path.join(os.homedir(), '.claude', 'settings.json'),
          path.join(os.homedir(), '.claude', 'settings.local.json')
        ];
        const expected=[
          'destructive-guard.sh','branch-guard.sh','syntax-check.sh','context-monitor.sh',
          'comment-strip.sh','cd-git-allow.sh','secret-guard.sh','api-error-alert.sh'
        ];
        const hooksDirExists=fs.existsSync(hooksDir);
        const hookFiles=hooksDirExists ? expected.filter((file)=>fs.existsSync(path.join(hooksDir,file))) : [];
        const settingsText=settingsFiles.filter((file)=>fs.existsSync(file)).map((file)=>fs.readFileSync(file,'utf8')).join('\n');
        const hooksRegistered=settingsText.includes('hooks') && (settingsText.includes('/hooks/') || expected.some((file)=>settingsText.includes(file)));
        console.log(JSON.stringify({hooksDirExists, hookFiles, hooksRegistered, hooksDir, settingsFiles: settingsFiles.filter((file)=>fs.existsSync(file))}));
    " 2>/dev/null
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_single_plugin() {
    local plugin="$1"
    case "$plugin" in
        cc-safe-setup)
            local detail
            detail=$(safe_setup_detail)
            [ -z "$detail" ] && return 1
            local hooks_dir_exists
            hooks_dir_exists=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hooksDirExists));" "$detail" 2>/dev/null)
            local hook_count
            hook_count=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hookFiles.length));" "$detail" 2>/dev/null)
            local hooks_registered
            hooks_registered=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hooksRegistered));" "$detail" 2>/dev/null)
            if [ "$hooks_dir_exists" = "true" ] && [ "$hook_count" -ge 4 ] && [ "$hooks_registered" = "true" ]; then
                return 0
            fi
            return 1
            ;;
        *)
            if command_exists "$plugin"; then
                return 0
            fi
            if npm list -g "$plugin" &>/dev/null 2>&1; then
                return 0
            fi
            return 1
            ;;
    esac
}

print_safe_setup_guidance() {
    local detail
    detail=$(safe_setup_detail)
    if [ -n "$detail" ]; then
        local hooks_dir
        hooks_dir=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hooksDir));" "$detail" 2>/dev/null)
        local hook_count
        hook_count=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hookFiles.length));" "$detail" 2>/dev/null)
        local hooks_registered
        hooks_registered=$(node -e "const d=JSON.parse(process.argv[1]); process.stdout.write(String(d.hooksRegistered));" "$detail" 2>/dev/null)
        log_note "  hooks dir:    $hooks_dir"
        log_note "  hook files:   $hook_count/8 expected"
        log_note "  registered:   $hooks_registered"
    fi
    if ! command_exists jq; then
        log_warn "  jq missing:   some hooks may fail"
    fi
    if ! command_exists gcc; then
        log_warn "  gcc missing:  syntax-check hook may fail"
    fi
    log_note "  install:      npx cc-safe-setup"
    log_note "  verify:       npx cc-safe-setup --doctor"
    log_note "  after:        restart Claude Code / AutoFish"
}

check_plugins() {
    local check_enabled
    check_enabled=$(config_val "plugins.check_on_startup" "true")
    [ "$check_enabled" != "true" ] && return 0

    local required
    required=$(plugin_list required)
    local optional
    optional=$(plugin_list optional)

    local missing_required=0

    for plugin in $required; do
        [ -z "$plugin" ] && continue
        if ! check_single_plugin "$plugin"; then
            log_error "[FATAL] Required plugin '$plugin' not installed or not active"
            [ "$plugin" = "cc-safe-setup" ] && print_safe_setup_guidance
            missing_required=1
            continue
        fi
        log_run "[PLUGIN] $plugin: installed (required)"
    done

    for plugin in $optional; do
        [ -z "$plugin" ] && continue
        if check_single_plugin "$plugin"; then
            log_run "[PLUGIN] $plugin: installed (optional)"
        else
            log_warn "[WARN] Optional plugin '$plugin' not installed or not active"
            [ "$plugin" = "cc-safe-setup" ] && print_safe_setup_guidance
        fi
    done

    [ "$missing_required" -eq 0 ] || return 1
    return 0
}

validate_project_doc() {
    local enabled
    enabled=$(config_val "project_validation.enabled" "true")
    [ "$enabled" != "true" ] && return 0

    if [ ! -f "$PROJECT_DOC_FILE" ]; then
        log_error "[FATAL] project.md not found at $PROJECT_DOC_FILE"
        log_note "  Create project.md with required sections and - [ ] tasks"
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
        log_error "[FATAL] project.md missing required sections:$missing_sections"
        return 1
    fi

    local task_format
    task_format=$(config_val "project_validation.task_format" "- [ ]")
    if ! grep -qF -e "$task_format" "$PROJECT_DOC_FILE"; then
        log_error "[FATAL] No tasks found in project.md (format: '$task_format')"
        return 1
    fi

    log_key "project.md validation: PASSED"
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
        log_error "[FATAL] Project bootstrap not confirmed"
        log_note "  Project config: $PROJECT_CONFIG_FILE"
        log_note "  Project doc:    $PROJECT_DOC_FILE"
        log_note "  Bootstrap:      status=$status, confirmed=$confirmed, config_decision=$config_decision"
        log_note "  Finish bootstrap Q&A in AutoFish before starting run-loop"
        return 1
    fi

    log_key "bootstrap confirmation: PASSED"
    return 0
}

check_safety() {
    init_git_state
    if ! command_exists claude; then
        log_error "[FATAL] claude command not found. Install: npm install -g @anthropic-ai/claude-code"
        return 1
    fi
    local cc_version
    cc_version=$(claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    log_key "Claude Code version: ${cc_version:-unknown}"
    if ! check_plugins; then
        return 1
    fi
    if [ ! -f "$PROMPT_TEMPLATE_FILE" ]; then
        log_error "[FATAL] auto-prompt.md not found at $PROMPT_TEMPLATE_FILE"
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

git_has_changes() {
    if ! $GIT_AVAILABLE; then
        return 1
    fi
    git add -A 2>/dev/null || true
    ! git diff --cached --quiet 2>/dev/null
}

commit_checkpoint() {
    local message="$1"
    local tmp_err
    tmp_err=$(mktemp)
    if git commit -m "$message" > /dev/null 2> "$tmp_err"; then
        rm -f "$tmp_err"
        return 0
    fi
    log_warn "Checkpoint commit failed: $message"
    log_note "  $(head -3 "$tmp_err" 2>/dev/null | tr '\n' ' ')"
    rm -f "$tmp_err"
    return 1
}

make_checkpoint() {
    case "$CHECKPOINT_MODE" in
        none)
            log_warn "Checkpoint skipped: checkpoint.mode=none"
            return 0
            ;;
    esac

    if ! $GIT_AVAILABLE; then
        log_warn "Checkpoint skipped: project is not a git repo"
        return 0
    fi

    if git_has_changes; then
        local ts
        ts=$(date '+%Y%m%d-%H%M%S')
        if commit_checkpoint "checkpoint: pre-autonomous $ts"; then
            log_key "Git checkpoint: $ts"
        fi
    else
        log_note "No uncommitted changes, skip checkpoint"
    fi
}

make_round_checkpoint() {
    local round="$1"
    local enabled
    enabled=$(config_val "git_checkpoint.enabled" "true")
    [ "$enabled" != "true" ] && return 0
    [ "$CHECKPOINT_MODE" = "none" ] && return 0
    $GIT_AVAILABLE || return 0

    local interval
    interval=$(config_val "git_checkpoint.interval_rounds" "1")
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
        log_warn "Round checkpoint skipped: invalid git_checkpoint.interval_rounds=$interval"
        return 0
    fi
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

    if git_has_changes && commit_checkpoint "$msg"; then
        log_key "Git checkpoint(r$round): $msg"
    fi
}

check_stop_conditions() {
    local round="$1"

    if [ -f "$STOP_FILE" ]; then
        echo "USER_STOP"
        return
    fi

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
            log_warn "Runtime limit reached: ${elapsed}min >= ${MAX_DURATION_MIN}min"
            echo "RUNTIME_LIMIT"
            return
        fi
    fi

    if [ -n "$STOP_AT" ]; then
        local now_time
        now_time=$(date +%H:%M)
        if [[ "$now_time" > "$STOP_AT" ]] || [ "$now_time" = "$STOP_AT" ]; then
            log_warn "Stop time reached: $now_time >= $STOP_AT"
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
        log_warn "Context ratio: accumulated $accumulated_turns turns >= threshold $safe_turns_by_ratio"
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
    log_run "Round $round"
    log_note "  Session mode: $([ "$SESSION_ACTIVE" = true ] && echo continue || echo fresh)"
    log_note "  Prompt file:  $PROMPT_TEMPLATE_FILE"
    log_note "  Stream mode:  $STREAM_PROGRESS"
    log_key "  Limits:       turns=$MAX_TURNS budget=\$$MAX_BUDGET"

    local exit_code=0
    local prompt_text
    prompt_text="$(build_runtime_context)

$(cat "$PROMPT_TEMPLATE_FILE")"
    log_note "Prompt: ${#prompt_text} chars from $PROMPT_TEMPLATE_FILE"

    local continue_flag=""
    if [ "$SESSION_ACTIVE" = true ]; then
        continue_flag="--continue"
        log_note "Round $round: continuing previous session"
    else
        log_note "Round $round: starting fresh session"
    fi

    local cache_flag="--exclude-dynamic-system-prompt-sections"
    local progress_filter="$AUTOFISH_ROOT/progress-filter.js"

    if [ "$STREAM_PROGRESS" = true ] && [ -f "$progress_filter" ]; then
        log_key "Mode: stream (filter: $progress_filter)"
        claude -p "$prompt_text" \
            $continue_flag \
            $cache_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            --verbose \
            --output-format stream-json \
            --include-partial-messages \
            2>"$tmp_err" | node "$progress_filter" "$LOG_FILE" "$round" 2>/dev/null \
            || exit_code=$?
    else
        log_warn "Mode: text (stream=$STREAM_PROGRESS, filter_exists=$([ -f "$progress_filter" ] && echo yes || echo no))"
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
        CURRENT_CC_PID=$!
        log_note "CC PID: $CURRENT_CC_PID"

        while kill -0 $CURRENT_CC_PID 2>/dev/null; do
            if [ -f "$STOP_FILE" ]; then
                kill -INT "$CURRENT_CC_PID" 2>/dev/null || true
                break
            fi
            local now_ts
            now_ts=$(date +%s)
            local elapsed=$((now_ts - start_ts))
            local min=$((elapsed / 60))
            local sec=$((elapsed % 60))
            local spin="${spin_chars:$spin_idx:1}"
            spin_idx=$(( (spin_idx + 1) % ${#spin_chars} ))
            if [ -n "$NO_COLOR_MODE" ] || [ ! -t 1 ]; then
                printf "\r  %s [%02d:%02d] CC 工作中..." "$spin" "$min" "$sec"
            else
                printf "\r%s  %s [%02d:%02d] CC 工作中...%s" "$c_run" "$spin" "$min" "$sec" "$c_reset"
            fi
            sleep 0.3
        done
        printf "\r\x1b[K"

        wait $CURRENT_CC_PID || exit_code=$?
        CURRENT_CC_PID=""

        cat "$tmp_log" >> "$LOG_FILE"
        cat "$tmp_log"
    fi

    if [ "$exit_code" -ne 0 ]; then
        local err_size
        err_size=$(wc -c < "$tmp_err" 2>/dev/null | tr -d '[:space:]')
        log_warn "CC stderr (${err_size:-0} bytes): $(head -3 "$tmp_err" 2>/dev/null | tr '\n' ' ')"
        local out_size
        out_size=$(wc -c < "$tmp_log" 2>/dev/null | tr -d '[:space:]')
        log_warn "CC stdout (${out_size:-0} bytes)"
    fi

    rm -f "$tmp_log" "$tmp_err"

    log_note "Round $round end (exit=$exit_code)"
    return $exit_code
}

generate_what_need_to_do() {
    log_run "Generating WhatNeedToDo.md (checklist format)..."

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
        log_key "WhatNeedToDo.md generated: $WNTD_FILE"
    else
        log_warn "[WARN] CC did not create WhatNeedToDo.md, generating fallback..."
        cat > "$WNTD_FILE" <<EOF
# AutoFish 阻塞处理指南

> 生成时间：$(date '+%Y-%m-%d %H:%M')
> 处理状态：待处理

## 阻塞任务清单

$(while IFS= read -r line; do [ -n "$line" ] && echo "- [ ] $line"; done < "$BLOCKED_FILE" 2>/dev/null)

## 已完成任务

$(cat "$DONE_FILE" 2>/dev/null || echo "无记录")

## 处理完成后

重新运行 AutoFish。主入口会优先拉起专用 WNTD Claude Code 窗口处理阻塞。
EOF
        log_warn "Fallback WhatNeedToDo.md created"
    fi
}

handle_what_need_to_do() {
    if [ ! -f "$WNTD_FILE" ]; then
        return 0
    fi

    log_run "Found existing WhatNeedToDo.md, analyzing user interaction..."

    local section
    section=$(sed -n '/^## 阻塞任务清单/,/^## /p' "$WNTD_FILE" 2>/dev/null)

    local unresolved
    unresolved=$(echo "$section" | grep -c "^- \[ \]" 2>/dev/null | tr -d '\r\n' || echo 0)
    local resolved
    resolved=$(echo "$section" | grep -c "^- \[x\]" 2>/dev/null | tr -d '\r\n' || echo 0)

    log_note "Blocked items in WNTD: $resolved resolved, $unresolved remaining"

    if [ "$unresolved" -eq 0 ] && [ "$resolved" -gt 0 ]; then
        log_key "All blocked items resolved by user, continuing execution..."
        rm -f "$WNTD_FILE"
        return 0
    fi

    if [ "$resolved" -gt 0 ]; then
        log_run "User resolved $resolved item(s), updating document via CC..."
        update_what_need_to_do

        local new_section
        new_section=$(sed -n '/^## 阻塞任务清单/,/^## /p' "$WNTD_FILE" 2>/dev/null)
        local new_unresolved
        new_unresolved=$(echo "$new_section" | grep -c "^- \[ \]" 2>/dev/null | tr -d '\r\n' || echo 0)

        if [ "$new_unresolved" -eq 0 ]; then
            log_key "CC resolved all remaining items during update, continuing..."
            rm -f "$WNTD_FILE"
            return 0
        fi

        log_warn "Still $new_unresolved item(s) need human review. See: $WNTD_FILE"
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
        log_warn "Blocks present and WNTD not yet reviewed by user."
        log_note "Edit: $WNTD_FILE (mark resolved as - [x], add notes), then restart."
        exit 0
    else
        log_warn "WNTD exists but no active blocked entries found. Keep file for manual review: $WNTD_FILE"
        exit 0
    fi
}

request_stop() {
    local signal="$1"
    STOP_REASON="USER_STOP"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $signal" > "$STOP_FILE"
    log_warn "Stop requested by signal: $signal"
    if [ -n "$CURRENT_CC_PID" ]; then
        kill -INT "$CURRENT_CC_PID" 2>/dev/null || true
    fi
}

trap 'request_stop INT' INT
trap 'request_stop TERM' TERM

main() {
    prepare_runtime_files
    handle_what_need_to_do
    reset_run_state

    log_sep
    log_key "Run summary"
    log_note "  Project id:   $PROJECT_ID"
    log_note "  Project root: $PROJECT_DIR"
    log_note "  Project doc:  $PROJECT_DOC_FILE"
    log_note "  Config:       $PROJECT_CONFIG_FILE"
    log_note "  Runtime dir:  $RUNTIME_DIR"
    log_key "  Limits:       turns=$MAX_TURNS budget=\$$MAX_BUDGET rounds=$MAX_ROUNDS sleep=${SLEEP_SEC}s"
    log_sep

    if ! check_safety; then
        log_error "[FATAL] Safety check failed, aborting"
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
        if [ -f "$STOP_FILE" ]; then
            stop_reason="USER_STOP"
            break
        fi

        echo "$round" > "$ROUND_FILE"

        if should_rebuild_session; then
            log_warn "Session rebuild triggered"
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

        if [ "$round_exit" -eq 0 ] && [ ! -f "$STOP_FILE" ]; then
            make_round_checkpoint "$round"
        fi

        if [ "$round_exit" -eq 0 ]; then
            SESSION_ACTIVE=true
            SESSION_ROUND_COUNT=$((SESSION_ROUND_COUNT + 1))
        else
            log_warn "Round $round failed (exit=$round_exit), will start fresh next round"
            SESSION_ACTIVE=false
            SESSION_ROUND_COUNT=0
        fi

        stop_reason=$(check_stop_conditions "$round")

        case "$stop_reason" in
            ALL_COMPLETE)
                log_key ">>> All tasks complete!"
                break
                ;;
            ALL_BLOCKED)
                log_warn ">>> All remaining tasks blocked, human review needed"
                generate_what_need_to_do
                break
                ;;
            MAX_ROUNDS)
                log_warn ">>> Max rounds reached ($MAX_ROUNDS)"
                break
                ;;
            RUNTIME_LIMIT)
                log_warn ">>> Runtime limit reached"
                break
                ;;
            STOP_TIME)
                log_warn ">>> Stop time reached"
                break
                ;;
            USER_STOP)
                log_warn ">>> User requested stop"
                break
                ;;
            CONTINUE)
                local current_done_lines=0
                [ -f "$DONE_FILE" ] && current_done_lines=$(wc -l < "$DONE_FILE" 2>/dev/null || echo 0)
                local delta=$((current_done_lines - last_done_lines))

                if [ "$current_done_lines" -gt "$last_done_lines" ]; then
                    stale_count=0
                    log_key "Round summary: done_delta=$delta stale_streak=$stale_count next=continue"
                    last_done_lines=$current_done_lines
                else
                    stale_count=$((stale_count + 1))
                    log_key "Round summary: done_delta=0 stale_streak=$stale_count next=continue"
                fi

                if [ "$stale_count" -ge 5 ]; then
                    log_warn ">>> ${stale_count} rounds with no progress, stopping"
                    echo "ALL_BLOCKED" >> "$BLOCKED_FILE"
                    generate_what_need_to_do
                    break
                fi
                ;;
        esac

        round=$((round + 1))
        log_key "Sleeping ${SLEEP_SEC}s..."
        local slept=0
        while [ "$slept" -lt "$SLEEP_SEC" ]; do
            [ -f "$STOP_FILE" ] && break
            sleep 1
            slept=$((slept + 1))
        done
    done

    log_sep
    log_key "Autonomous dev loop ended"
    log_key "Total rounds: $round | Reason: $stop_reason"
    log_sep

    echo ""
    if [ -n "$NO_COLOR_MODE" ] || [ ! -t 1 ]; then
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
        if $GIT_AVAILABLE; then
            echo "Rollback: git log --oneline | grep 'pre-autonomous'"
        else
            echo "Rollback: unavailable (non-git project / checkpoint skipped)"
        fi
        echo ""
    else
        colorize "$c_key" "=== Summary ==="; printf '\n'
        colorize "$c_note" "Project id:   $PROJECT_ID"; printf '\n'
        colorize "$c_note" "Project doc:  $PROJECT_DOC_FILE"; printf '\n'
        colorize "$c_note" "Runtime dir:  $RUNTIME_DIR"; printf '\n'
        colorize "$c_key" "Total rounds: $round"; printf '\n'
        colorize "$c_key" "Stop reason:  $stop_reason"; printf '\n\n'
        colorize "$c_key" "=== Files ==="; printf '\n'
        colorize "$c_note" "Done:         $DONE_FILE"; printf '\n'
        colorize "$c_note" "Blocked:      $BLOCKED_FILE"; printf '\n'
        colorize "$c_note" "Log:          $LOG_FILE"; printf '\n\n'
        colorize "$c_key" "=== Next actions ==="; printf '\n'
        colorize "$c_note" "Review files above."; printf '\n'
        if $GIT_AVAILABLE; then
            colorize "$c_note" "Rollback: git log --oneline | grep 'pre-autonomous'"; printf '\n'
        else
            colorize "$c_note" "Rollback: unavailable (non-git project / checkpoint skipped)"; printf '\n'
        fi
        printf '\n'
    fi
}

main "$@"
