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

# init — truncate without adding empty lines
: > "$LOG_FILE"
: > "$DONE_FILE"
: > "$BLOCKED_FILE"
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
    if ! grep -qF -e "$task_format" "$doc_file"; then
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

# ========== round checkpoint (smart, with descriptive message) ==========
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

    # Build descriptive message from recently completed tasks
    local msg=""
    if [ -f "$DONE_FILE" ]; then
        # Take last 3 done entries for the commit message
        local latest
        latest=$(tail -3 "$DONE_FILE" 2>/dev/null | grep -oP '\]\s+\K.+?(?=\s*—|\s*$)' 2>/dev/null || \
                 tail -3 "$DONE_FILE" 2>/dev/null | sed 's/.*\] //; s/ —.*//; s/PROGRESS: //; s/SESSION_RESET//')
        if [ -n "$latest" ]; then
            msg=$(echo "$latest" | tr '\n' ';' | sed 's/;$//; s/;/, /g')
        fi
    fi

    if [ -z "$msg" ]; then
        msg="round $round checkpoint"
    fi

    msg="autofish(r$round): $msg"

    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "$msg" 2>/dev/null || true
        log "Git checkpoint(r$round): $msg"
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
    local tmp_err
    tmp_err=$(mktemp)

    log_sep
    log "Round $round start"

    local exit_code=0

    local prompt_text
    prompt_text=$(cat "$PROMPT_FILE")
    log "Prompt: ${#prompt_text} chars from $PROMPT_FILE"

    local continue_flag=""
    if [ "$SESSION_ACTIVE" = true ]; then
        continue_flag="--continue"
        log "Round $round: continuing previous session"
    else
        log "Round $round: starting fresh session"
    fi

    # Cache optimization: exclude dynamic sections from system prompt
    local cache_flag="--exclude-dynamic-system-prompt-sections"

    local progress_filter="${SCRIPT_DIR}/progress-filter.js"

    if [ "$STREAM_PROGRESS" = true ] && [ -f "$progress_filter" ]; then
        # Stream mode with clean progress filter
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
        # Non-stream mode with spinner indicator
        log "Mode: text (stream=$STREAM_PROGRESS, filter_exists=$([ -f "$progress_filter" ] && echo yes || echo no))"
        local spin_chars="⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
        local spin_idx=0
        local start_ts
        start_ts=$(date +%s)

        # Launch CC in background
        claude -p "$prompt_text" \
            $continue_flag \
            $cache_flag \
            --permission-mode auto \
            --max-turns "$MAX_TURNS" \
            --max-budget-usd "$MAX_BUDGET" \
            > "$tmp_log" 2>"$tmp_err" &
        local cc_pid=$!
        log "CC PID: $cc_pid"

        # Spinner overlay while CC runs
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
        printf "\r\x1b[K"  # Clear spinner line

        wait $cc_pid || exit_code=$?

        cat "$tmp_log" >> "$LOG_FILE"
        cat "$tmp_log"
    fi

    # Diagnostic: show stderr if CC failed
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

# ========== WhatNeedToDo handling ==========
WNTD_FILE="${PROJECT_DIR}/.asdf/WhatNeedToDo.md"

generate_what_need_to_do() {
    log "Generating WhatNeedToDo.md (checklist format)..."

    local summary_prompt
    summary_prompt=$(cat << 'PROMPT_EOF'
你是一个项目状态总结助手。AutoFish 在自动执行过程中遇到了阻塞，需要你来分析并生成一份**交互式**处理指南。

## 关键要求：使用 checkbox 清单格式

你必须使用 `- [ ]` 格式列出每个阻塞项。这样用户可以在处理完后将 `- [ ]` 改为 `- [x]`，下次 AutoFish 启动时会自动识别。

## 工作步骤

1. 阅读 `.asdf/project.md` — 项目任务清单
2. 阅读 `.asdf/task-done.txt` — 已完成任务
3. 阅读 `.asdf/task-blocked.txt` — 阻塞任务
4. 阅读 `.asdf/auto-log.txt` 最后50行 — 了解上下文

5. 使用 Write 工具创建 `.asdf/WhatNeedToDo.md`，严格按此格式：

```markdown
# AutoFish 阻塞处理指南

> 生成时间：[当前时间]
> 处理状态：0/N 已解决
> AutoFish 在自动执行过程中遇到需要人工介入的问题，已自动暂停。

## 阻塞概览
[2-3句话概括]

## 阻塞任务清单（逐个处理，处理完打勾）

- [ ] **任务名1**
  - **阻塞原因**：XXX
  - **你需要做什么**：具体的操作步骤（改哪个文件、做什么决策）
  - **备选方案**（如是设计决策）：A. XXX B. XXX → 推荐：XXX
  - **用户反馈**：（在此写下你的决定/说明）

- [ ] **任务名2**
  - **阻塞原因**：XXX
  - **你需要做什么**：XXX
  - **用户反馈**：（在此写下你的决定/说明）

## 已完成任务（本轮自动完成）
[从 task-done.txt 列出]

## 待执行任务（阻塞解除后自动继续）
[从 project.md 列出尚未开始的 - [ ] 任务]

## 用户反馈区
> 在此区域写任何补充说明、全局决策、方案选择。
> 你的文字会被保留，不会被 AutoFish 覆盖。

## 处理指南

1. 处理上面列出的每个 `- [ ]` 阻塞项
2. 处理完后将 `- [ ]` 改为 `- [x]`
3. 在"用户反馈"行写下你的解决方案/决定
4. 重新双击 `run-auto.bat` 启动 AutoFish
5. AutoFish 会识别你的处理结果并自动继续
```

## 注意
- 中文
- 每个阻塞项必须是 `- [ ]` 开头（这是关键的交互格式）
- 每个阻塞项下必须有"用户反馈："行供用户填写
- 信息要具体可操作
PROMPT_EOF
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
        cat > "$WNTD_FILE" << FALLBACK_EOF
# AutoFish 阻塞处理指南

> 生成时间：$(date '+%Y-%m-%d %H:%M')
> 处理状态：待处理

## 阻塞任务清单

$(while IFS= read -r line; do [ -n "$line" ] && echo "- [ ] $line"; done < "$BLOCKED_FILE" 2>/dev/null)

## 已完成任务

$(cat "$DONE_FILE" 2>/dev/null || echo "无记录")

## 处理完成后

重新运行 AutoFish。脚本会自动检测阻塞是否已解决。
FALLBACK_EOF
        log "Fallback WhatNeedToDo.md created"
    fi
}

update_what_need_to_do() {
    log "Updating WhatNeedToDo.md (preserving user input)..."

    local update_prompt
    update_prompt=$(cat << 'PROMPT_EOF'
你是一个项目状态更新助手。用户已阅读 WhatNeedToDo.md 并对部分阻塞项做了处理（标记 `- [x]`、写了反馈）。

## 关键原则：增量更新，绝不覆盖用户内容

1. **必须保留**所有用户标记的 `- [x]` 项及其下方用户写的全部内容
2. **必须保留**"用户反馈区"中用户写的所有文字
3. **只更新**仍然为 `- [ ]` 的项：检查其阻塞状态是否发生变化
4. **不要重写整个文档**。只改变化的部分

## 工作步骤

1. 阅读 `.asdf/WhatNeedToDo.md` — 了解用户已处理了什么
2. 阅读 `.asdf/task-blocked.txt` — 检查阻塞状态是否有变化
3. 阅读 `.asdf/project.md` — 确认任务状态

4. 更新 WhatNeedToDo.md：
   - 如果某个 `- [ ]` 实际上已经被用户用其他方式解决了：改为 `- [x]` 并简短说明
   - 如果有新的阻塞出现（之前文档没列出的）：追加 `- [ ]` 项
   - 如果某个阻塞原因已过时：更新原因描述
   - 更新"处理状态"计数：X/N 已解决
   - 更新"生成时间"
   - **用户写的任何内容都保留不动**

5. 如果用户通过"用户反馈区"给出了全局决策（如"全部用方案A"），据此更新各阻塞项

## 注意
- 不要删除用户文字
- 不要重新生成整个文档
- 更新完仍然有 `- [ ]` 项是正常的（用户还需要处理）
PROMPT_EOF
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

    # Extract only the "阻塞任务清单" section to avoid counting
    # items from "待执行任务" section or code-block examples
    local section
    section=$(sed -n '/^## 阻塞任务清单/,/^## /p' "$WNTD_FILE" 2>/dev/null)

    local unresolved
    unresolved=$(echo "$section" | grep -c "^- \[ \]" 2>/dev/null | tr -d '\r\n' || echo 0)
    local resolved
    resolved=$(echo "$section" | grep -c "^- \[x\]" 2>/dev/null | tr -d '\r\n' || echo 0)

    log "Blocked items in WNTD: $resolved resolved, $unresolved remaining"

    # Case 1: All blocked items resolved → integrate and continue execution
    if [ "$unresolved" -eq 0 ] && [ "$resolved" -gt 0 ]; then
        log "All blocked items resolved by user, continuing execution..."
        rm -f "$WNTD_FILE"
        return 0
    fi

    # Case 2: User has interacted (some [x]) → CC updates the doc preserving user input
    if [ "$resolved" -gt 0 ]; then
        log "User resolved $resolved item(s), updating document via CC..."
        update_what_need_to_do

        # RE-CHECK after CC update — CC may have resolved remaining items
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

    # Case 3: No [x] items yet — user hasn't interacted with the checklist
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
        log "No active blocks found, removing WNTD and continuing..."
        rm -f "$WNTD_FILE"
        return 0
    fi
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

    # Check if previous block was resolved by human
    handle_what_need_to_do

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
        local round_exit=$?

        # Smart checkpoint after each round (interval configurable)
        make_round_checkpoint "$round"

        # Only continue session if round was successful (exit=0)
        # Failed rounds mean CC couldn't work — continuing them is useless
        if [ "$round_exit" -eq 0 ]; then
            SESSION_ACTIVE=true
            SESSION_ROUND_COUNT=$((SESSION_ROUND_COUNT + 1))
        else
            log "Round $round failed (exit=$round_exit), will start fresh next round"
            SESSION_ACTIVE=false
            SESSION_ROUND_COUNT=0
        fi

        local stop_reason
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
    echo "=== Results ==="
    echo "  Done tasks:    cat $DONE_FILE"
    echo "  Blocked tasks: cat $BLOCKED_FILE"
    echo "  Full log:      cat $LOG_FILE"
    echo ""
    echo "To rollback: git log --oneline | grep 'pre-autonomous'"
    echo ""
}

main "$@"
