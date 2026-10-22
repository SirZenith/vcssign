# archive/ — 已完成开发

镜像 `../workspace/` 的模块目录结构：`archive/<module>/<file>`。
迭代文档实现完成后从 `workspace/<module>/` 移入（并更新状态行）。

## 模块列表

`bootstrap/`、`vcs/`、`repo/`、`sidebar/`、`commands/`、`testing/`、`signs/`、`perf/`。

对应关系（把 M0–M6 的计划文件按主题拆进模块目录）：

| 模块 | 归档文档 | 状态 |
|---|---|---|
| `bootstrap/` | `2026-10-16T20-52-42-master-plan.md` | 已实现、冻结 |
| `bootstrap/` | `2026-10-16T20-52-42-implementation-todo-index.md` | 已实现、冻结 |
| `vcs/` | `2026-10-16T17-33-54-vcs-adapter-git-svn.md` | 已实现、冻结 |
| `repo/` | `2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` | 已实现、冻结 |
| `sidebar/` | `2026-10-16T17-33-54-sidebar-ui.md` | **M6 已退役**，仅作历史记录 |
| `commands/` | `2026-10-16T17-33-54-commands-and-actions.md` | 已实现、冻结 |
| `testing/` | `2026-10-16T17-33-54-testing-infra-and-toolchain.md` | 已实现、冻结 |
| `signs/` | `2026-10-16T23-24-18-line-signs-in-signcolumn.md` | 已实现、冻结 |
| `signs/` | `2026-10-21T14-53-19-signs-vanish-after-save.md` | 已完成（D51/D52） |
| `signs/` | `2026-10-22T10-49-40-signs-vanish-when-the-status-view-predates-the-save.md` | 已完成（D53） |
| `perf/` | `2026-10-19T11-33-42-m7-performance-review.md` | 已完成（M7 七步全部落地），**本文是 `08`；先看 §2.10 前后总表** |

## 命名与时间戳

归档文档的命名规则与 workspace 相同（`<YYYY-mm-ddTHH-MM-SS>-<slug>.md`），但时间戳取
**该文档最后一笔 git 提交的时间**（而不是迁移时间），因此可复现；`bootstrap/` 下两篇共用
同一个时间戳（同一批计划文档在同一提交里冻结）。

例外：文档正文里仍使用旧编号指代（`00`–`07`、`03 §7.3`、`05 §4` 这类），正文编号保持
原样不重写，便于与 git 历史和代码注释对照。

## 简写对照表（`00`–`08`）

| 简写 | 归档文档 | 原计划文件 |
|---|---|---|
| `00` | `loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` | `00-overview.md` |
| `01` | `loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` | `01-vcs-adapter.md` |
| `02` | `loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` | `02-repo-runtime.md` |
| `03` | `loop/archive/sidebar/2026-10-16T17-33-54-sidebar-ui.md` | `03-sidebar-ui.md` |
| `04` | `loop/archive/commands/2026-10-16T17-33-54-commands-and-actions.md` | `04-commands-actions.md` |
| `05` | `loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md` | `05-testing-infra.md` |
| `06` | `loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` | `06-todo.md` |
| `07` | `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` | `07-signs-in-signcolumn.md` |
| `08` | `loop/archive/perf/2026-10-19T11-33-42-m7-performance-review.md` | `08-perf-review.md`（M7 性能/架构审查） |

代码与测试的注释直接引用上表里的归档文档（例如 `--- See
loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md §6.`）；`D1`–`D48`
的一行摘要见 [`../knowledge/decisions.md`](../knowledge/decisions.md)。

## 被抽取的小节

可复用的事实已抽取到 [`../knowledge/`](../knowledge/README.md) 与
[`../workspace/`](../workspace/README.md)；归档文档正文里的对应小节**只留指针**
（一段 `本节已抽取到…` 的引用块），不再维护，历史信息全文在新文档里。抽取范围：

| 归档文档 | 抽取到 |
|---|---|
| `bootstrap/…-master-plan.md` §2 / §4 | `knowledge/ecosystem/prior-art.md` / `knowledge/decisions.md` |
| `bootstrap/…-implementation-todo-index.md` 附录 A1 / A2、「M6 之后」 | `knowledge/vcs/git-output-formats.md` / `knowledge/vcs/svn-output-formats.md` / `knowledge/nvim/signs-and-extmarks.md` |
| `vcs/…-vcs-adapter-git-svn.md` §4 / §5 / §6.1 | `knowledge/vcs/git-output-formats.md` / `knowledge/vcs/svn-output-formats.md` / `knowledge/nvim/libuv-and-vim-system.md` |
| `repo/…-repo-runtime-and-refresh-pipeline.md` §2 / §3.2 / §6 | `knowledge/nvim/libuv-and-vim-system.md` / `knowledge/lua/pitfalls.md` |
| `sidebar/…-sidebar-ui.md` §3.3 | `knowledge/nvim/signs-and-extmarks.md` |
| `commands/…-commands-and-actions.md` §7.3 | `workspace/commands/…-backlog-commands-and-actions.md` |
| `testing/…-testing-infra-and-toolchain.md` §3 / §4 / §5 / §7 | `knowledge/testing/headless-nvim.md` |
| `signs/…-line-signs-in-signcolumn.md` §2 / §5.1–5.5 / §6.3 / §9 / §10 / §11 | `knowledge/nvim/signs-and-extmarks.md` / `knowledge/nvim/libuv-and-vim-system.md` / `knowledge/nvim/diff-and-hunks.md` / `knowledge/vcs/svn-output-formats.md` / `knowledge/lua/pitfalls.md` / `knowledge/ecosystem/prior-art.md` / `workspace/signs/…-backlog-signs-and-diff.md` / `workspace/testing/…-backlog-ci-and-test-hygiene.md` |

## bootstrap/ — 冻结

M0–M6 的引导阶段（总规划 + ADR + 实施步骤总索引），**完整且冻结**：计划、状态表与各步骤
工作文档全部留在该目录内，是纯历史记录。铁律在根
[`loop/README.md`](../README.md) 指向的总规划里，稳定知识在
[`../knowledge/`](../knowledge/README.md)。

不要在 `archive/bootstrap/` 下新增或修改文档（除修正指针外）；新工作写在
[`../workspace/`](../workspace/README.md) 里。
