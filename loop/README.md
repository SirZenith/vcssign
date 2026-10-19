# loop/ — 迭代与知识索引

本目录是 vcssign 的**规划与知识库**，不包含任何代码（代码在 `lua/` 与 `plugin/`）。
按「是否已开发完成」与「是否与单个功能绑定」分成三个子目录；本文件只保留对它们的
索引，各子目录的详细说明在自己的 `README.md` 里。

```
loop/
├── README.md      ← 本文件：子目录索引
├── workspace/     ← 尚未完成开发的迭代文档（活跃工作区）
├── archive/       ← 已完成开发的迭代文档（含冻结的 bootstrap/）
└── knowledge/     ← 与单个功能无关、可复用的知识
```

| 子目录 | 说明 | 详细说明 |
|---|---|---|
| [`workspace/`](./workspace/README.md) | 尚未完成开发的迭代文档；每模块最新一篇 = 当前任务 | [`workspace/README.md`](./workspace/README.md) |
| [`archive/`](./archive/README.md) | 已完成开发的迭代文档（含冻结的 `bootstrap/`） | [`archive/README.md`](./archive/README.md) |
| [`knowledge/`](./knowledge/README.md) | 与单个功能无关、可复用的知识 | [`knowledge/README.md`](./knowledge/README.md) |

全局约定：`loop/` 只放规划与知识，**不放代码**；`lua/` 与 `plugin/` 只放代码，
**不放规划文档**（对应 pi-wingman 的 `loop/` ↔ `packages/` 约定）。

铁律（硬规则）来源：归档后的 M0–M6 总规划
[`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md`](./archive/bootstrap/2026-10-16T20-52-42-master-plan.md)
（含 ADR `D1`–`D48`）与用户可见契约 [`doc/vcssign.txt`](../doc/vcssign.txt)；对任何改动
（任何阶段）都具有约束力。同一份规划里的实现步骤总索引是
[`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`](./archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md)。

## 简写约定

归档文档、workspace 文档与代码注释里用 `00`–`08` 指代归档文档、`D<n>` 指代 ADR
（如 `03 §7.3`、`05 §4`、`07 §10`）。对照表见
[`archive/README.md`](./archive/README.md)；`D<n>` 的一行摘要见
[`knowledge/decisions.md`](./knowledge/decisions.md)。

文档之间的引用一律写**仓库根相对路径**（如 `loop/knowledge/vcs/git-output-formats.md`），
不写 `../` 相对路径，便于从任意目录检索。
