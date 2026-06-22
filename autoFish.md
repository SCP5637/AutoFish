# AutoFish — CC 全自动开发脚本系统

> 命名由来：扔下鱼饵（prompt），鱼自己上钩（CC 自动滚动开发）。你睡觉，它干活。
> 版本：v2.0 | 2026-05-25

---

## 目录

1. [这是什么](#1-这是什么)
2. [核心原理](#2-核心原理)
3. [文件结构](#3-文件结构)
4. [使用方式](#4-使用方式)
5. [运行流程图](#5-运行流程图)
6. [停止条件](#6-停止条件)
7. [安全机制](#7-安全机制)
8. [结果验收](#8-结果验收)
9. [故障排查](#9-故障排查)
10. [已知限制](#10-已知限制)
11. [后续开发方向](#11-后续开发方向)

---

## 1. 这是什么

AutoFish 是一套让 Claude Code **无人值守自动滚动开发**的脚本系统。

核心思路：一个上层入口 `autoFish.bat` 双击启动 → 默认转发到 `run-auto.bat` → 菜单选择项目 → 外层 `while` 循环 → 每轮启动一个新的 CC 非交互会话 → CC 读取集中式 `project.md` 逐项完成 → 会话结束 → 自动开始下一轮 → 直到所有任务完成或需要人工介入时停止。

**实战验证**：2026-05-25 凌晨，AutoFish 在 SokobanLike 项目中连续运行 8 轮（约 1.5 小时），自动完成了 **C0.2 到 C2.8 共 19 个子阶段**的全部代码实现，包括：
- 四方向移动 + 撞墙检测 + 动画
- 全部 5×4 箱子物理规则表
- 圆柱箱双格系统
- 球箱持续滚动 + 磁力连锁递归
- 10000 步撤销/重做
- raygui 编辑器（画笔/填充/选择/Playtest 切换）
- BFS 可解性验证器
- CMake 构建系统 + 编译通过

---

## 2. 核心原理

```
┌──────────────────────────────────────────────────────────┐
│                      autoFish.bat                        │
│  1. 上层入口，默认转发到 run-auto.bat                        │
│                                                          │
│                      run-auto.bat                         │
│  1. 检测 CC 是否安装（友好错误提示）                         │
│  2. 探测 bash.exe 位置（6 个常见路径）                      │
│  3. 注入 Git usr/bin + mingw64 gcc 到 PATH                │
│  4. 读取 config.json → show_cc_window 则启动监察窗口       │
│  5. git commit checkpoint（自动回滚点）                     │
│  6. 启动 bash run-loop.sh                                │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │                   run-loop.sh                       │  │
│  │  safety checks:                                    │  │
│  │    • .git exists?  claude available?               │  │
│  │    • project.md valid?  plugins ok?                │  │
│  │                                                    │  │
│  │  while (未达停止条件) {                              │  │
│  │    1. 检查会话重建条件（轮次/上下文/标记）             │  │
│  │    2. 读取 auto-prompt.md 作为本轮任务指令            │  │
│  │    3. claude -p "$prompt"                            │  │
│  │       --continue (会话复用) 或 新会话                 │  │
│  │       --permission-mode auto                         │  │
│  │       --max-turns 50   (可配置)                      │  │
│  │       --max-budget-usd 5.00  (可配置)                │  │
│  │       --output-format stream-json  (可配置)          │  │
│  │    4. 等待 CC 完成                                   │  │
│  │    5. 检查停止条件（含运行时限制）                     │  │
│  │    6. 等待 N 秒 → 下一轮                             │  │
│  │  }                                                   │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │               state/projects/<project-id>/              │  │
│  │  config.json    ← 每项目运行配置                        │  │
│  │  project.md     ← 任务清单（CC 每轮读取）              │  │
│  │  runtime/       ← 本项目运行状态目录                   │  │
│  │    auto-log.txt ← 完整运行日志                         │  │
│  │    task-done.txt ← 已完成 + SESSION_RESET 信号         │  │
│  │    task-blocked.txt ← 阻塞项                           │  │
│  └────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────┘
```

**关键设计**：
- 每轮 CC 都重新读取 `auto-prompt.md` 和 `project.md`，从第一个未完成的 `- [ ]` 开始。
- 默认启用 **会话复用**（`--continue`）：后续轮次复用上一轮上下文，CC 能参考之前的对话。通过 `config.json` 的 `session.rebuild_strategy` 控制何时重建全新会话。
- 进度通过 `project.md` 的 `[x]` 标记和 `task-done.txt` 持久化，跨轮保持。
- 支持 `stream-json` 实时进度输出，可选的独立监察窗口。
- 支持运行时长限制和定时停止，防止无限运行。

---

## 3. 文件结构

```
项目根目录/
├── autoFish.bat              ← 源文件：Windows 上层入口
├── run-auto.bat              ← 源文件：Windows 实际启动器
├── run-loop.sh               ← 源文件：bash 循环引擎
├── auto-prompt.md            ← 源文件：通用任务提示模板
├── bootstrap-seed.md         ← 源文件：新项目 bootstrap 提示
├── autoFish.md               ← 源文件：用户手册（本文件）
├── PROJECT_SPEC.md           ← 源文件：project.md 格式规范
├── autofish.js               ← 源文件：项目菜单/注册表/路径控制器
└── state/                    ← 运行态目录（gitignored）
    └── projects/
        └── <project-id>/
            ├── config.json    ← 每项目运行配置
            ├── project.md     ← 项目主文档（含任务清单 - [ ] 勾选项）
            └── runtime/
                ├── auto-log.txt
                ├── task-done.txt
                ├── task-blocked.txt
                ├── auto-round.txt
                └── WhatNeedToDo.md
```

**核心文件的关系**：

| 文件 | 谁读 | 用途 |
|------|------|------|
| `autoFish.bat` | 你（双击） | Windows 上层入口。默认调用 `run-auto.bat`，为后续分层扩展预留稳定入口 |
| `run-auto.bat` | `autoFish.bat` 或你直接运行 | 实际启动器。找 `claude`/`node`/`bash` → 注入 PATH → 调 `autofish.js` |
| `autofish.js` | `run-auto.bat` 调用 | 控制面。显示项目菜单、读取 `state/configList.json`、探测项目路径、创建每项目 state、决定是 bootstrap 还是进入 run-loop |
| `run-loop.sh` | `autofish.js` 调用 | 循环引擎。在目标项目目录里运行 Claude，但配置/日志/阻塞状态都读取集中 state 路径 |
| 根 `config.json` | `autofish.js` + `run-loop.sh` 读取 | 根默认配置模板。新项目创建时复制为每项目 `config.json` |
| `state/projects/<project-id>/config.json` | `run-loop.sh` 读取 | 每项目运行配置：项目路径、预算、轮次、插件、显示、校验 |
| `auto-prompt.md` | CC 每轮读取 | 通用任务定义。实际文件路径由运行时上下文注入 |
| `state/projects/<project-id>/project.md` | CC 每轮读取 | 项目主文档。技术栈 + 任务清单 + 开发规则 |
| `bootstrap-seed.md` | 新项目初始化时读取 | 引导 Claude 先理解 `PROJECT_SPEC.md`，再与用户对话生成 `project.md` |

### 3.6 配置文件（config.json）— v2.0 新增

所有运行时参数由 AutoFish 根 `config.json` 作为默认模板，项目实际运行时读取 `state/projects/<project-id>/config.json`。缺失时回退到默认值。

**完整配置项：**

| 分类 | 字段 | 默认值 | 说明 |
|------|------|--------|------|
| 基础 | `project_dir` | `"./"` | 项目根目录（覆盖自动检测） |
| 基础 | `max_turns_per_round` | `50` | 每轮最大 turns |
| 基础 | `max_budget_per_round_usd` | `5.00` | 每轮预算上限（美元） |
| 基础 | `max_rounds` | `200` | 最大轮数 |
| 基础 | `sleep_between_rounds_sec` | `5` | 轮间休息秒数 |
| 会话 | `session.rebuild_strategy.mode` | `"any"` | 会话重建组合模式：`any`（OR）或 `all`（AND） |
| 会话 | `session.rebuild_strategy.every_n_rounds` | `null` | 每 N 轮强制重建会话（null=禁用） |
| 会话 | `session.rebuild_strategy.context_ratio_threshold` | `null` | 上下文使用率阈值 0.0~1.0（null=禁用） |
| 会话 | `session.rebuild_strategy.respect_task_markers` | `true` | 是否响应 project.md 中的 `[RESET]` 标记 |
| 运行时 | `runtime.max_duration_minutes` | `null` | 最大运行时长（分钟，null=无限制） |
| 运行时 | `runtime.stop_at` | `null` | 定时停止时间 HH:MM（null=禁用） |
| 插件 | `plugins.required` | `[]` | 强制插件列表（缺失则拒绝启动） |
| 插件 | `plugins.optional` | `["cc-safe-setup"]` | 可选插件列表（缺失仅警告） |
| 插件 | `plugins.auto_install_missing` | `false` | 是否自动安装缺失的可选插件 |
| 插件 | `plugins.check_on_startup` | `true` | 启动时是否检查插件状态 |
| 显示 | `display.show_cc_window` | `false` | 是否打开独立 CC 监察窗口 |
| 显示 | `display.stream_realtime_progress` | `true` | 是否使用 stream-json 实时输出 |
| 校验 | `project_validation.enabled` | `true` | 是否校验 project.md 格式 |
| 校验 | `project_validation.required_sections` | `["技术栈","任务清单"]` | 必须包含的章节 |
| 校验 | `project_validation.task_format` | `"- [ ]"` | 任务行格式 |

**默认值即 v1.0 行为**——不改任何配置，AutoFish 行为和旧版一致。

### 3.5 依赖：cc-safe-setup 安全钩子（安装指南）

AutoFish 让 CC 在无人值守状态下连续运行数小时。**没有钩子 = 裸奔。** 社区记录了大量事故：`rm -rf /` 从根目录删除用户数据、`git push --force` 凌晨推未测试代码到 main、语法错误级联污染 30+ 文件。

> **v2.0 变更**：cc-safe-setup 从硬依赖变为**可配置**。在 `config.json` 的 `plugins` 中调整：
> - `plugins.optional: ["cc-safe-setup"]` → 缺失仅警告（默认）
> - `plugins.required: ["cc-safe-setup"]` → 缺失则拒绝启动（旧行为）
> - `plugins.required: []` → 完全跳过检查（不推荐）

#### 安装命令

```bash
npx cc-safe-setup
```

安装过程中提示 `Install all 8 safety hooks? [Y/n]`，输入 `Y`。

#### 依赖

钩子脚本依赖两个工具，安装前确保可用：

| 工具 | 用途 | 安装方式 |
|------|------|----------|
| **jq** | JSON 解析（钩子需解析 settings.json） | Windows: 从 [jqlang/releases](https://github.com/jqlang/jq/releases) 下载 `jq-windows-amd64.exe` → 放到 Git usr/bin/ 下 |
| **gcc** | Post-Edit 语法检查（编辑 .c 文件后自动 `gcc -fsyntax-only`） | Windows: `winget install BrechtSanders.WinLibs.POSIX.MSVCRT` |

#### 八个钩子详解

| # | 钩子名 | 触发时机 | 作用 | 不装的后果 |
|---|--------|----------|------|-----------|
| 1 | **Destructive Command Blocker** | PreToolUse(Bash) | 拦截 `rm -rf` / `git reset --hard` / `git checkout --force` / `git push --force` / `DROP TABLE` 等 | CC 凌晨可能删除整个项目目录 |
| 2 | **Branch Push Protector** | PreToolUse(Bash) | 拦截 `git push` 到 main/master，拦截未经 CI 的 force push | 凌晨未测试代码直接推到 main |
| 3 | **Post-Edit Syntax Validator** | PostToolUse(Edit\|Write) | 每次编辑 .c/.h 文件后自动跑 `gcc -fsyntax-only`，发现语法错误立即阻止 | 一个语法错误污染后续所有编辑，级联到 30+ 文件 |
| 4 | **Context Window Monitor** | PostToolUse(*) | 追踪工具调用次数作为上下文代理，在阈值 40%/25%/20%/15% 时自动注入 `/compact` | 超过 150 次工具调用后静默丢失全部上下文状态 |
| 5 | **Bash Comment Stripper** | PreToolUse(Bash) | 剥离 bash 命令中的注释，修复注释破坏权限白名单匹配的 bug | 带注释的命令被权限系统误判，导致合法命令被拒 |
| 6 | **cd+git Auto-Approver** | PreToolUse(Bash) | 自动批准 `cd` + `git status/log/diff` 等只读组合操作，减少权限弹窗 | 每轮 CC 被权限弹窗卡住，自动化无法持续 |
| 7 | **Secret Leak Prevention** | PreToolUse(Bash) | 检测 `git add` 的文件列表中是否包含 `.env`/`credentials`/`secret` 等敏感文件名 | CC 凌晨 `git add .` 把 API key 提交到公开仓库 |
| 8 | **API Error Session Alert** | Stop | CC 因 API 限流/429/账单欠费等原因退出时，在日志中写入告警而非静默死亡 | 自动化会话静默终止，你早上发现什么都没做 |

#### 验证钩子生效

```bash
# 安装后重启 CC，运行验证：
npx cc-safe-setup --doctor
```

#### 钩子配置存储位置

```
C:\Users\<用户名>\.claude\
├── hooks/
│   ├── destructive-guard.sh
│   ├── branch-guard.sh
│   ├── syntax-check.sh
│   ├── context-monitor.sh
│   ├── comment-strip.sh
│   ├── cd-git-allow.sh
│   ├── secret-guard.sh
│   └── api-error-alert.sh
└── settings.json          ← hooks 注册配置在此文件中
```

> **警告**：钩子安装后必须**重启 Claude Code** 才能生效。如果 CC 正在运行中，关闭重新打开。

---

## 4. 使用方式

### 前置条件

1. **Windows** + Git for Windows（提供 bash）
2. **Claude Code** 已安装并在 PATH 中
3. **目标项目** 是可访问的 git 项目目录（没有 `project.md` 时会先进入五阶段 bootstrap 问答；只有 bootstrap 明确确认后才允许自动开发）
4. **cc-safe-setup 8 个安全钩子已安装**（**强烈推荐**，v2.0 可配置，详见 §3.5）

### 启动

```
双击 run-auto.bat
```

### 运行中

- 终端窗口会显示每轮进度
- `auto-log.txt` 记录完整日志
- 按 `Ctrl+C` 可随时停止（git checkpoint 已自动创建，可回滚）

### 睡前操作

```bash
# 1. 确认 project.md 任务清单是最新的
# 2. 确认 auto-prompt.md 中的项目路径正确
# 3. 双击 run-auto.bat
# 4. 去睡觉
```

### 早上验收

```bash
# 1. 查看完成的任务
cat state/projects/<project-id>/runtime/task-done.txt

# 2. 查看阻塞项
cat state/projects/<project-id>/runtime/task-blocked.txt

# 3. 查看 git 变更摘要
git diff --stat HEAD~N   # N = 完成的轮数

# 4. 编译验证
cmake -B build && cmake --build build

# 5. 满意 → git add -A && git commit -m "review: autonomous session approved"
#    不满意 → git reset --hard <checkpoint commit>
```

---

## 5. 运行流程图

```
双击 run-auto.bat
  │
  ├─ [1] 检测 CC / Node / bash
  │     └─ 任一缺失 → 报错退出
  │
  ├─ [2] 注入 PATH
  │     ├─ Git usr/bin
  │     └─ mingw64/bin (gcc)
  │
  ├─ [3] 启动 autofish.js
  │     │
  │     ├─ 读取 state/configList.json
  │     ├─ 显示菜单：继续上次 / 已注册项目 / New Project / Exit
  │     ├─ 路径探测与项目确认
  │     ├─ 创建或复用 state/projects/<project-id>/
  │     └─ 判断 project.md 是否存在
  │           │
  │           ├─ 不存在
  │           │   └─ 打开 Claude bootstrap 窗口
  │           │      ├─ 阶段1：读取规范与项目事实
  │           │      ├─ 阶段2：多轮细化需求
  │           │      ├─ 阶段3：确认特殊开发偏好
  │           │      ├─ 阶段4：展示草案并确认生成 project.md
  │           │      └─ 阶段5：确认是否定制 config.json
  │           │
  │           └─ 已存在
  │               ├─ 若 bootstrap 未确认 → 继续 bootstrap review
  │               └─ 若 bootstrap 已确认 → 调 run-loop.sh
  │                   │
  │                   ├─ 安全检查
  │                   │   ├─ git 项目可用
  │                   │   ├─ claude 可用
  │                   │   ├─ 插件检查
  │                   │   ├─ 校验 bootstrap confirmed
  │                   │   └─ 校验集中式 project.md
  │                   │
  │                   └─ while (轮数 < max_rounds)
  │                         ├─ 检查会话重建条件
  │                         ├─ 拼接 runtime context + auto-prompt.md
  │                         ├─ claude -p "$prompt" [--continue]
  │                         ├─ 写入 runtime/task-done.txt / task-blocked.txt / SESSION_RESET
  │                         ├─ 检查停止条件
  │                         └─ 等待 N 秒 → 下一轮
  │
  └─ 结束，显示结果摘要
```

---

## 6. 停止条件

| 条件 | 触发方式 | 含义 |
|------|----------|------|
| **ALL_COMPLETE** | CC 在 `task-done.txt` 中写入此标记 | project.md 所有 `- [ ]` 已变 `- [x]` |
| **ALL_BLOCKED** | CC 在 `task-blocked.txt` 中写入此标记 | 剩余任务全部需要人工决策 |
| **连续5轮无进展** | 脚本检测 `task-done.txt` 行数不增加 | 可能陷入死循环或 CC 无法完成任务 |
| **MAX_ROUNDS** | 脚本计数达到 `max_rounds`（默认 200） | 安全上限，防止无限运行 |
| **RUNTIME_LIMIT** | 运行时长达到 `runtime.max_duration_minutes` | v2.0 新增。定时停止，防止无限运行 |
| **STOP_TIME** | 当前时间 >= `runtime.stop_at`（HH:MM） | v2.0 新增。如设置 `"06:00"`，早上6点停止 |

`RUNTIME_LIMIT` 和 `STOP_TIME` 以先到者为准。默认均为 `null`（禁用），行为与 v1.0 一致。

---

## 7. 安全机制

### 7.1 Git Checkpoint

每轮开始前自动 `git commit`。出问题可 `git reset --hard` 回到自动运行前的状态。

### 7.2 Permission Mode: auto

CC 使用 `--permission-mode auto`（Anthropic 2026年3月发布），分类器评估每次工具调用。自动阻止：
- `curl | bash`
- `git push --force`
- 批量删除
- 3 次连续拒绝 → 降级终止

### 7.3 cc-safe-setup 8 钩子（v2.0：可配置）

AutoFish 的安全防线分为两层：内层是 CC 自带的 `--permission-mode auto`，外层是操作系统级的钩子。两层互补——auto mode 的 17% 漏报率（高危操作未被拦截）由钩子兜底。

> **v2.0 变更**：cc-safe-setup 不再是硬依赖。在 `config.json` 中通过 `plugins` 配置：
> - `plugins.optional: ["cc-safe-setup"]` — 缺失仅警告，继续运行（默认）
> - `plugins.required: ["cc-safe-setup"]` — 缺失则拒绝启动（严格模式）
> - `plugins.required: [], plugins.optional: []` — 完全跳过插件检查

详见 §3.5 的安装指南和钩子详解。这里总结钩子在自动化循环中的具体作用：

| 钩子 | 在 AutoFish 循环中的作用 |
|------|------------------------|
| Destructive Command Blocker | 防止 CC 在无人值守时执行 `rm -rf` / `git reset --hard` / force push |
| Branch Push Protector | 防止凌晨自动 push 未测试代码到 main |
| Syntax Validator | 每轮 CC 编辑 .c 文件后自动检查语法，错误立即发现不对后续轮次产生连锁污染 |
| Context Monitor | 每轮 50 turns 内，在上下文接近耗尽时自动 `/compact` |
| Comment Stripper | 确保权限白名单匹配不受注释干扰 |
| cd+git Auto-Approver | 减少权限弹窗，防止无人值守时卡在等待人类确认 |
| Secret Leak Prevention | 防止 CC `git add .` 时误提交敏感文件 |
| API Error Alert | CC 因 API 故障退出时写入告警，而非静默死亡（静默死亡 = 你早上发现什么都没做） |

**钩子未安装的风险**：AutoFish 仍会运行，但上述 8 类事故无任何防护。社区 108 小时无人值守实测中，无钩子运行时出现了 7 种不同类型的故障。

### 7.4 预算上限

`--max-budget-usd 5.00` 每轮。200 轮理论最大 $1000，实际上每轮通常在 $1-3。

### 7.5 自动截停

`auto-prompt.md` 中明确规定 CC 在遇到设计决策、架构变更、安全问题时**必须停止并记录**到 `task-blocked.txt`，不自作主张。

---

## 8. 结果验收

### 验收清单

早上起床后，按以下顺序检查：

```
□ 1. 读 task-done.txt → 了解 CC 完成了什么
□ 2. 读 task-blocked.txt → 了解 CC 卡在哪里，需要你做什么决定
□ 3. 读 auto-log.txt 最后 50 行 → 快速了解运行概况
□ 4. git diff --stat → 看改了多少文件
□ 5. git log --oneline | head -20 → 看 commit 历史（每轮结束可能没有 commit，但 checkpoint 有）
□ 6. 编译 + 运行 → 确认代码能跑
□ 7. 快速浏览关键源文件 → 确认代码质量可接受
□ 8.  满意 → 处理阻塞项，更新 project.md 任务清单，准备下一轮
□ 9.  不满意 → git reset --hard <checkpoint> 回滚，分析原因，调整 auto-prompt.md
```

### 常见验收结果

| 情况 | 处理方式 |
|------|----------|
| 代码能编译，功能正常 | ✅ 验收通过，处理阻塞项，继续 |
| 代码能编译，但部分功能有 bug | 手动修或让 CC 修（在 project.md 加 bugfix 任务） |
| 代码不能编译 | 查 auto-log.txt 中的编译错误，可能是缺依赖或环境差异 |
| CC 走错方向，写了一堆没用的 | 调整 auto-prompt.md 的任务描述，回滚重来 |

---

## 9. 故障排查

| 症状 | 原因 | 解决 |
|------|------|------|
| `[ERROR] bash.exe not found` | Git for Windows 不在标准路径 | 手动编辑 `.bat`，在 for 循环中加你的路径 |
| `date: command not found` | PATH 未注入 Git usr/bin | 检查 `.bat` 中 `%GIT_USR_BIN%` 是否正确 |
| `claude: command not found` | CC 不在 PATH | `npm install -g @anthropic-ai/claude-code` 或加 CC 路径到系统 PATH |
| CC 输出乱码 | CMD/Bash 编码问题 | `.bat` 已用纯 ASCII，`.sh` 中文在 bash 中正常 |
| CC 反复做同一任务 | project.md 的 `[x]` 未正确标记 | 检查 CC 是否有 Edit 权限编辑 project.md |
| 连续 5 轮无进展后停止 | CC 遇到了它不会做的事 | 读 task-blocked.txt，手动处理阻塞项 |
| CC 删除了不该删的文件 | 安全钩子未生效 | 确认 cc-safe-setup 已安装且 CC 重启过。运行 `npx cc-safe-setup --doctor` 验证 |
| 钩子安装失败 / jq not found | jq 未安装 | 从 GitHub 下载 jq-windows-amd64.exe，放到 `C:\Program Files\Git\usr\bin\jq.exe` |
| 语法检查钩子不工作 | gcc 不在 PATH | `winget install BrechtSanders.WinLibs.POSIX.MSVCRT`，确认 gcc 在 PATH 中 |
| 钩子导致 CC 变慢 | 语法检查钩子每次编辑后跑 gcc | 正常现象，语法检查耗时 < 1s。如影响体验可临时禁用 syntax-check 钩子 |
| `config.json` 不生效 | JSON 语法错误（如多余逗号） | 用 `node -e "JSON.parse(require('fs').readFileSync('state/projects/<project-id>/config.json','utf8'))"` 验证 JSON 合法性 |
| 会话复用导致 CC 方向偏离 | `--continue` 累积过多上下文 | 在 project.md 任务中加 `[RESET]` 标记，或降低 `session.rebuild_strategy.every_n_rounds` |
| 插件检查报错但已安装 | `check_single_plugin` 检测逻辑不完善 | 将对应插件从 `plugins.required` 移到 `plugins.optional`，或设置 `plugins.check_on_startup: false` |
| 运行时限制未触发 | 时间格式错误或时区问题 | `stop_at` 使用 24 小时制本地时间，格式为 `HH:MM`（如 `"06:00"`）。`max_duration_minutes` 为整数分钟 |

---

## 10. 已知限制

1. **设计决策不行**。CC 不能判断"这个关卡好不好玩"、"这个机制该不该加"、"这个配色好不好看"。
2. **视觉/音频不行**。美术资源和音频需要人工创作或专门的 AI 工具。
3. **跨文件大重构不行**。涉及 5+ 文件的架构级改动，CC 在 50 turns 内难以高质量完成。
4. **环境差异**。CC 运行时的 PATH、依赖与你手动运行时的环境可能不同。
5. **Token 消耗**。一晚（8-10 轮）约消耗 $15-40 API 费用（取决于模型和任务密度）。
6. **会话上下文累积**。v2.0 默认使用 `--continue` 复用会话，长运行后上下文可能膨胀。通过 `session.rebuild_strategy` 控制重建时机。

---

## 11. 后续开发方向

AutoFish 本身作为一个独立工具可以进一步开发：

### 短期（v2.1）

- [ ] 支持多项目切换（`run-auto.bat --project <path>`）
- [ ] 每轮开始前自动 `git pull`（如果追踪了远程分支）
- [ ] 异常轮次自动重试（CC 崩溃时等待更长时间后重试，最多 N 次）
- [ ] 日志轮转（auto-log.txt 超过 10MB 时归档）
- [ ] 进度通知（完成后发桌面通知/Webhook）

### 中期（v2.2）

- [ ] 多项目并行（同时跑多个项目的自动化）
- [ ] 定时启动（设置"每晚 2 点自动开始"）
- [ ] Slack/Discord/微信通知集成
- [ ] 智能任务分配（根据任务类型选择不同的 prompt 策略）
- [ ] 自修复循环（检测到编译错误后自动追加一轮 bugfix）

### 长期（v3.0）

- [ ] **Flutter 桌面 GUI 应用**：将 AutoFish 从终端脚本升级为跨平台桌面应用（详见 `FLUTTER_RESEARCH.md` 调研笔记）
- [ ] 学习型 prompt（根据之前轮次的成功率自动调整 prompt 内容）
- [ ] VS Code 插件集成

---

> **项目地址**：`E:\WorkSpace\github\AutoFish\`
> **版本历史**：v1.0 初始发布 → v2.0 引入 config.json 配置系统、会话复用、stream-json 实时进度、插件可配置化、运行时限制。
> **自举开发**：AutoFish v2.0 由 AutoFish v1.0 自动开发完成（11 个任务，无人值守）。
