# archive/ — 已完成开发

镜像 `../workspace/` 的模块目录结构：`archive/<module>/<file>`。
迭代文档实现完成后从 `workspace/<module>/` 移入（并更新状态行），命名规则与 workspace
相同（见 [`../workspace/README.md`](../workspace/README.md) 的「文件命名」）。

## 模块列表

`actions/`、`milestones/`、`perf/`、`sidebar/`。

| 模块 | 文档 | 收尾状态 |
|---|---|---|
| `actions` | `actions/2026-10-15T15-07-15-commands-and-actions.md` | 已实现：命令族、动作（stage / diff / commit / reset）、autocmd 生命周期。M7 步骤 5 又改过动作层的刷新与 staged 判定，改动记在 `perf` §2.9 |
| `milestones` | `milestones/2026-10-15T19-25-37-milestone-tracker.md` | 已完结：M0–M7 逐项勾选的总清单，含各里程碑的验收与踩坑记录 |
| `perf` | `perf/2026-10-19T11-33-42-m7-performance-review.md` | 已完成：M7 性能/架构审查（P0-1…P0-5、P1-1…P1-3、P2-1…P2-6、S1 全部落地）。**先看 §2.10「M7 前后总表」** |
| `sidebar` | `sidebar/2026-10-15T15-07-15-sidebar-ui.md` | **已退役**：M6 Step 1（`080379c`）把方向改成行级 sign，侧边栏代码与其 spec 全部删除；本文留作 M3 的设计与验收记录，不再作为实现依据（当前实现见 `signs`） |

## 归档规矩

- 只追加，不改写历史结论：文档里的实测数字与当时的选择保持原样；后续推翻或修订，
  在原文处加引用块（`> **M7 步骤 N 修正**：…`）并指向新文档，而不是回头改数字。
- 归档文档仍在被引用（代码注释、帮助、`knowledge/` 各篇），所以**不要改文件名**。
- 归档不等于失效：`sidebar` 是唯一一篇「已退役」的，其余五篇描述的都是当前实现。
