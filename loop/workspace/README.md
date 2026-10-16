# workspace/ — 尚未完成开发（活跃工作区）

按功能模块分目录（`workspace/<module>/`），**每个模块目录里最新的一篇迭代文档
就是该模块的当前任务**。实现完成后，把文档移到
[`../archive/<module>/`](../archive/README.md) 并更新其状态行。

## 目录语义

- 新功能的迭代文档写在 `workspace/<module>/`（目录不存在则创建），命名见下节。
- 不符合 `<时间戳>-<slug>.md` 命名的文件（如本 `README.md`）是目录索引，
  **不是**迭代文档，不参与「最新文档 = 当前任务」的判定。
- 每篇迭代文档头部带一行状态：`[ ] 未开始` / `[~] 进行中` / `[x] 已完成`
  （`[x]` 的文档应移入 `archive/<module>/`）。

## 文件命名

迭代文档统一命名为：

```
<YYYY-mm-ddTHH-MM-SS>-<slug>.md
```

- `<YYYY-mm-ddTHH-MM-SS>` 是 ISO 8601 本地时间戳（日期与时间用 `T` 分隔），例如
  `2026-10-16T23-59-34-backlog-signs-and-diff.md`。
- `<slug>` 是功能的简短 kebab-case 概括；不带 `step-` 前缀、不带 phase 编号。
- 时间戳不含空格，因此这类路径**无需**用 `<...>` 包裹即可在 Markdown 中链接。

（例外：`archive/` 下冻结的 M0–M6 引导文档保留原有的 `00`–`07` 编号命名，
见 [`../archive/README.md`](../archive/README.md)。）

## 活跃文档索引

| 模块 | 活跃文档 | 出处 |
|---|---|---|
| `signs/` | `2026-10-16T23-59-34-backlog-signs-and-diff.md`（[`07 §10`](../archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md) + `07 §11`） | M6 行级 sign |
| `commands/` | `2026-10-16T23-59-34-backlog-commands-and-actions.md`（[`04 §7.3`](../archive/commands/2026-10-16T17-33-54-commands-and-actions.md)） | M4 命令与动作 |
| `testing/` | `2026-10-16T23-59-34-backlog-ci-and-test-hygiene.md`（`05 §4` + `07 §11.5`） | M5 测试基建 |
