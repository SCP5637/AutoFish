# PROJECT_SPEC.md — AutoFish 项目文档格式规范

> 版本：v2.0
> 面向：使用 AutoFish 进行无人值守自动开发的项目维护者

---

## 1. 概述

AutoFish 通过读取项目主文档（`project.md`）来获取任务清单、技术栈信息和开发规则。
本文档定义了 `project.md` 的格式规范，确保 CC（Claude Code）能正确解析并执行任务。

---

## 2. 文件位置

AutoFish 按以下优先级查找 project.md：

1. `state/projects/<project-id>/project.md`（推荐位置）
2. `project.md`（仓库根目录，兼容导入）

建议放在 AutoFish 根目录的 `state/projects/<project-id>/project.md` 中，由 AutoFish 集中管理。仓库根目录 `project.md` 仅作为兼容导入入口。

---

## 3. 最小结构

project.md 必须包含以下内容：

### 3.1 技术栈章节

```markdown
## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | ... |
| 框架 | ... |
| 构建系统 | ... |
```

CC 需要知道项目的技术栈才能正确选择实现方式。

### 3.2 任务清单章节

```markdown
## 任务清单

- [ ] 任务1描述
- [ ] 任务2描述
- [x] 已完成的任务
```

project.md 草案可以先生成并等待用户确认；只有在 bootstrap 明确确认后，AutoFish 才会允许进入自动开发。

### 3.3 开发规则章节（可选但强烈建议）

```markdown
## 开发规则

1. 规则1
2. 规则2
```

项目特定的编码规则，会覆盖 `auto-prompt.md` 中的默认规则。

---

## 4. 任务格式

### 4.1 基本格式

```
- [ ] 任务描述
```

- `- [ ]`（中间有一个空格）表示未完成
- `- [x]` 表示已完成
- CC 按从上到下顺序处理，完成后将 `- [ ]` 改为 `- [x]`

### 4.2 特殊标记

任务后可以附加可选标记：

```
- [ ] 某任务描述 [RESET]
- [ ] 某任务描述 [BLOCK]
```

| 标记 | 含义 | 行为 |
|------|------|------|
| `[RESET]` | 会话重建 | 完成此任务后，CC 写入 `SESSION_RESET` 信号，外部脚本在下一轮启动全新 CC 会话（不带 --continue）。用于关键里程碑后重置上下文。 |
| `[BLOCK]` | 预标记阻塞 | 提示 CC 此任务可能需要人工决策。CC 遇到困难时应更快地放弃并写入 `task-blocked.txt`，而非反复尝试。 |

### 4.3 任务分组

建议使用 Phase/阶段分组：

```markdown
### Phase 1：基础设施

- [ ] 任务1.1
- [ ] 任务1.2

### Phase 2：核心功能

- [ ] 任务2.1
```

CC 不解析分组，仅按文档中 `- [ ]` 的出现顺序处理。

---

## 5. 配置与任务清单的交互

`config.json` 中的以下配置会影响任务执行行为：

| 配置项 | 影响 |
|--------|------|
| `max_turns_per_round` | 每轮 CC 的最大 turns，超限后外部脚本启动新的一轮 |
| `max_rounds` | 最大轮数，达到后停止循环 |
| `runtime.max_duration_minutes` | 运行时长上限，超时后优雅停止 |
| `runtime.stop_at` | 定时停止时间（HH:MM），到时间后停止 |
| `session.rebuild_strategy.every_n_rounds` | 每 N 轮强制重建会话 |
| `session.rebuild_strategy.respect_task_markers` | 是否响应任务清单中的 `[RESET]` 标记 |

CC 从 `config.json` 读取这些配置，但不需要主动管理会话重建——会话管理由外部脚本（`run-loop.sh`）负责。

---

## 6. 完整示例

以下是一个完整的 `project.md` 示例：

```markdown
# MyProject — 自动开发任务

## 技术栈

| 组件 | 技术 |
|------|------|
| 语言 | TypeScript 5.x |
| 运行时 | Node.js 20+ |
| 框架 | Express 4.x |
| 数据库 | SQLite (better-sqlite3) |
| 测试 | Vitest |
| 构建工具 | tsc + esbuild |

## 开发规则

1. 不引入新的 npm 依赖（任务明确要求的除外）
2. 所有 API 路由需有输入校验
3. 错误使用中文，面向中国用户
4. 测试覆盖率不低于 80%

## 任务清单

### Phase 1：基础设施

- [x] 1.1 初始化项目结构
- [x] 1.2 配置 TypeScript 和构建脚本
- [ ] 1.3 添加数据库 Schema 和迁移

### Phase 2：API 实现

- [ ] 2.1 实现用户注册接口
- [ ] 2.2 实现用户登录接口（JWT）
- [ ] 2.3 实现密码重置流程 [BLOCK]

### Phase 3：前端集成 [RESET]

- [ ] 3.1 创建 React 前端项目
- [ ] 3.2 实现登录页面

## 附录

- 数据库文件位置：`data/app.db`
- 环境变量：见 `.env.example`
```

---

## 7. task-done.txt 格式

每完成一个任务，CC 自动追加一行：

```
[YYYY-MM-DD HH:MM] 任务描述 — 完成
```

特殊信号行：

| 内容 | 含义 |
|------|------|
| `SESSION_RESET` | CC 请求外部脚本下一轮重建会话 |
| `ALL_COMPLETE` | 所有任务完成，外部脚本停止循环 |
| `ALL_BLOCKED` | 所有剩余任务需要人工决策 |
| `PROGRESS: 已完成 N 个任务，继续中` | 本轮 turns 耗尽但还有未完成任务 |

---

## 8. task-blocked.txt 格式

遇到需要人工决策的情况时，CC 追加：

```
[YYYY-MM-DD HH:MM] 任务描述 — 阻塞原因: [说明为什么需要人工决策]
```

阻塞原因类型：
- **设计决策类** — 功能行为、UX/UI、算法选择需要人工判断
- **架构变更类** — 涉及新增模块、修改 API、跨文件重构
- **安全/风险类** — 涉及文件系统写、网络通信、认证相关
- **不确定类** — 任务歧义、矛盾、信息不足

---

## 9. 常见问题

**Q: project.md 可以放多个任务清单吗？**
A: 可以。CC 会扫描整个文件，按所有 `- [ ]` 的出现顺序处理。

**Q: bootstrap 生成了 project.md 后会立刻开始自动开发吗？**
A: 不会。bootstrap 只是收集需求并生成草案。只有用户明确确认 project.md，且决定是否定制每项目 `config.json` 后，AutoFish 才会允许进入自动开发。

**Q: CC 会修改 project.md 以外的文件吗？**
A: 在 bootstrap 会话中，默认只允许修改 `project.md` 和可选的每项目 `config.json`。进入 run-loop 后，CC 才会按任务描述修改源文件。

**Q: 如何让 CC 跳过某个任务？**
A: 在 project.md 中删除该任务的 `- [ ]` 行，或将其改为注释（`<!-- - [ ] 任务 -->`）。不要在任务行前加 `#` 注释——CC 可能仍会识别。

**Q: [RESET] 和 [BLOCK] 标记可以同时使用吗？**
A: 可以。`- [ ] 某任务 [RESET] [BLOCK]` 同时具有两个标记的效果。
