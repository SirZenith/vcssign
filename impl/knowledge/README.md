# 知识库（impl/knowledge）

本目录固化与实现**紧密相关的稳定知识**——接口契约、语义约定、实测结论、测试方法。
`knowledge/` 回答 **「为什么这样做 / 事实是什么」**；「这次改了什么」在
[`../archive/`](../archive/README.md)，「接下来做什么」在 [`../workspace/`](../workspace/README.md)。

> 唯一权威来源仍是源码与 `doc/vcssign.txt`；本目录是经过核验的**摘要 + 指针**。
> 基准环境：Neovim 0.12.4（LuaJIT）、git 2.55、svn 1.14.5、Windows 11。

模块名就是正文里的引用句柄（`见 vcs §3`= 本目录 `vcs/` 下那篇的 §3）。

## 索引

| 文档 | 内容 | 主要来源 |
|---|---|---|
| [`overview/`](./overview/2026-10-15T15-07-15-goals-architecture-and-decisions.md) | 目标与非目标、gitsigns / oil-vcs-status 参考架构、总体分层、关键决策 **D1–D46** | 本文即原 `impl/init/00-overview.md` |
| [`vcs/`](./vcs/2026-10-15T15-07-15-vcs-adapter-contract.md) | `VcsSystem` 契约：`find_root_sync` / `get_root_async` / `show` / `blame` / `apply_patch` / `status` / `metadata_dir` / `baseline_stamp` / `metadata_recursive` / `open_blob_reader`，`capabilities` 与 git、svn 两个适配器的全部实测 | `lua/vcssign/vcs/{base,git,svn}.lua`、`test/vcs_*_spec.lua` |
| [`runtime/`](./runtime/2026-10-15T15-07-15-repo-runtime.md) | `exec`（一次性子进程 + `stream` 常驻）→ `Repo`（存活探测、status 视图、blob reader、`changed_paths`、`watch_recursive`）→ 刷新管线；去抖、句柄池、错误退避 | `lua/vcssign/{exec,repo,repo_manager,debounce}.lua` |
| [`testing/`](./testing/2026-10-15T15-07-15-testing-infrastructure.md) | `temp/` fixture 的构造与状态矩阵、TAP 脚手架（`test/run.lua` + `helpers`）、进程计数与通知断言规矩、lint / CI、文档回写 | `scripts/make_test_repos.sh`、`test/**`、`Makefile` |
| [`signs/`](./signs/2026-10-16T11-43-18-signs-in-signcolumn.md) | M6 主线：`vim.text.diff` → hunk → extmark sign 的完整规则、双层 sign（staged / unstaged）、导航与窗口、预览与词级 diff、blame、rev diff、以及「必须先测后写」的反直觉约束 | `lua/vcssign/{attach,signs,hunk,nav,preview,worddiff,blame,revdiff}.lua` |

## 速查

- **适配器加一个 VCS**：先读 `vcs` §3（契约）与 §7（验收清单），再照 `git.lua` 抄一个；
  可选钩子（`status` / `baseline_stamp` / `open_blob_reader` / `metadata_dir` /
  `metadata_recursive`）不实现也能工作，只是回到逐文件提问的旧路。
- **改渲染路径**：`signs` §3.2（hunk → sign 的映射）与 §4（高亮组）；`perf` §3 P0-4
  解释了「基线指纹 + `changedtick` 短路」为什么必须留。
- **加一条进程**：`perf` §6.1 是进程预算表（git / svn 各一套），`test/proc_budget_spec.lua`
  会当场把预算顶破；改预算要同时改文档。
- **写注释指向计划文档**：用目录形式（`impl/knowledge/vcs/`），见 [`../README.md`](../README.md)
  的「引用约定」——`luacheck` 120 列与 vim help 78 列都容不下完整路径。
