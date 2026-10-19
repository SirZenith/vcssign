# impl/ — 规划与知识索引

本目录是 vcssign 的**规划与知识库**，不包含任何代码（代码在 `lua/`，测试在 `test/`，
用户手册在 `doc/vcssign.txt`）。按「是否已完成开发」与「是否与单个功能绑定」分成三个
子目录；本文件只保留对它们的索引与引用约定。

```
impl/
├── README.md      ← 本文件：子目录索引 + 模块速查
├── workspace/     ← 尚未完成开发的迭代文档（活跃工作区）
├── archive/       ← 已完成开发的迭代文档
└── knowledge/     ← 与单个功能无关、可复用的知识（契约、语义、方法）
```

| 子目录 | 说明 | 详细说明 |
|---|---|---|
| [`workspace/`](./workspace/README.md) | 尚未完成开发的迭代文档；每模块最新一篇 = 当前任务 | [`workspace/README.md`](./workspace/README.md) |
| [`archive/`](./archive/README.md) | 已完成开发的迭代文档 | [`archive/README.md`](./archive/README.md) |
| [`knowledge/`](./knowledge/README.md) | 与单个功能无关、可复用的知识 | [`knowledge/README.md`](./knowledge/README.md) |

全局约定：`impl/` 只放规划与知识，**不放代码**；`lua/` 与 `test/` 只放代码，**不放规划文档**。

## 模块与文档

**模块名 = 目录名 = 正文里的引用句柄。** 文档里写「见 `perf` §6」，就是指
`impl/archive/perf/` 下那篇的 §6；写「见 `vcs` §7.3」就是 `impl/knowledge/vcs/` 下那篇。
一个模块目录里目前只有一篇文档，所以句柄不需要带文件名。

| 模块 | 位置 | 文档 | 状态 |
|---|---|---|---|
| `overview` | `knowledge/` | `2026-10-15T15-07-15-goals-architecture-and-decisions.md` | 长期维护（目标、参考架构、关键决策 D1–D46） |
| `vcs` | `knowledge/` | `2026-10-15T15-07-15-vcs-adapter-contract.md` | 长期维护（`VcsSystem` 契约：git / svn 适配器、可选钩子） |
| `runtime` | `knowledge/` | `2026-10-15T15-07-15-repo-runtime.md` | 长期维护（`exec` / `Repo` / status 视图 / blob reader / FS 监听 / 刷新管线） |
| `testing` | `knowledge/` | `2026-10-15T15-07-15-testing-infrastructure.md` | 长期维护（`temp/` fixture、TAP 脚手架、lint / CI、断言规矩） |
| `signs` | `knowledge/` | `2026-10-16T11-43-18-signs-in-signcolumn.md` | 已实现（M6 主线：行级 sign、hunk 动作、导航、预览、blame、rev diff） |
| `sidebar` | `archive/` | `2026-10-15T15-07-15-sidebar-ui.md` | **已退役**（M6 Step 1 `080379c` 删掉侧边栏，留作设计与验收记录） |
| `actions` | `archive/` | `2026-10-15T15-07-15-commands-and-actions.md` | 已实现（命令族、动作、autocmd 生命周期） |
| `milestones` | `archive/` | `2026-10-15T19-25-37-milestone-tracker.md` | 已完成（M0–M7 逐项勾选的总清单） |
| `perf` | `archive/` | `2026-10-19T11-33-42-m7-performance-review.md` | 已完成（M7 性能/架构审查；**§2.10 是前后总表**） |

## 引用约定

- **文档之间**用完整路径（`impl/knowledge/vcs/2026-10-15T15-07-15-vcs-adapter-contract.md`）
  或模块句柄（`vcs §3`）——两者都能落到唯一一篇；跨目录跳转优先写完整路径。
- **代码与手册里的注释**用目录形式（`impl/knowledge/vcs/`）：`lua/` 的注释受
  `luacheck` 的 120 列约束，`doc/vcssign.txt` 受 vim help 的 78 列约束，长路径会顶破。
- 每篇文档头部都有 `模块 / 状态 / 原编号` 一行，从那里可以回到本页。

## 命名与生命周期

迭代文档统一命名为 `<YYYY-mm-ddTHH-MM-SS>-<slug>.md`（ISO 8601 本地时间戳，`T` 分隔；
slug 是功能的 kebab-case 概括）。`README.md` 是目录索引，不参与「最新文档 = 当前任务」的判定。

一篇文档的生命周期：写在 `workspace/<module>/` → 实现完成后更新状态行并移到
`archive/<module>/`；若其中有可以脱离本次迭代复用的契约/语义/方法，抽到
`knowledge/<module>/`。详见各子目录的 `README.md`。

## 历史：从 `impl/init/` 的编号系列切换过来

2026-10-15 起的计划系列是 `impl/init/00-overview.md` … `08-perf-review.md`
（overview–perf 是稳定编号，正文里大量「见 perf §6」这样的引用）。2026-10-19 按上面的布局重整：
九篇原样搬进 `knowledge/` 与 `archive/` 的模块目录，文件名带上「首次提交时间戳 + slug」，
正文里的编号引用一并改成模块句柄（`08 §6` → `perf §6`），代码/手册注释指向所在目录。
文档内容没有被删改，只动了标题行、头部元信息与引用写法。
