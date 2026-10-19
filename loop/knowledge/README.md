# 知识库（loop/knowledge）

本目录固化与开发过程**紧密相关的稳定知识**——外部命令的输出格式、Neovim/libuv 的
API 语义、生态先例、测试方法。`knowledge/` 回答 **"为什么这样做 / 事实是什么"**。

> 唯一权威来源仍是源码与官方文档；本目录是经过核验的**摘要 + 指针**。
> 版本基准：Neovim 0.12.4、`git` / `svn` 本机实测（2026-10）。
> 每篇文档正文从归档文档**原文抽取**（只下移标题层级），末尾标出 `*来源：…*`。

引用知识文档时写上完整路径（如 `loop/knowledge/nvim/signs-and-extmarks.md`）；
本文件是详细索引与速查表。

## 索引

| 文档 | 内容 | 主要来源 |
|---|---|---|
| [`./ecosystem/prior-art.md`](./ecosystem/prior-art.md) | gitsigns.nvim / vcs-helper.nvim / oil-vcs-status 的借鉴点与避坑项；与本插件的有意差异表（不做 async 框架、内置 diff、无 `:Gitsigns` 命令族、svn 单层 sign、reset 不做内存内 patch） | `loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` §2、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §9 |
| [`./vcs/git-output-formats.md`](./vcs/git-output-formats.md) | `status --porcelain=v1 -z` 字节流与 rename 双段、`core.quotepath`、`LC_ALL=C`、`MSYS=noglob`、`--no-optional-locks`、`rev-parse --show-toplevel` / `gitdir:` 解析、实测字节流样本 | `loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §4、`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` 附录 A1 |
| [`./vcs/svn-output-formats.md`](./vcs/svn-output-formats.md) | 7 状态列 + 第 9 列起路径、CRLF/反斜杠、tree-conflict `>` 续行、`svn info --show-item wc-root`、`svn patch --strip` 语义与死亡组合、实测样本 | `loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §5、`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` 附录 A2、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.3/§11.2 |
| [`./nvim/libuv-and-vim-system.md`](./nvim/libuv-and-vim-system.md) | 递归监听（Linux 不支持）、**从不报告被监听目录自身消失**、删目录后事件风暴须 `stop()+close()`、`vim.system` 退出回调在 fast-event 上下文、`pcall` 包 ENOENT、超时定时器先建后 spawn、`stdin` 尾换行语义 | `loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` §2/§3.2、`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §6.1、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.1/§5.5 |
| [`./nvim/signs-and-extmarks.md`](./nvim/signs-and-extmarks.md) | 双 extmark sign 位与 priority（窄列保留高优先级）、extmark vs `:sign`、`'signcolumn'` 由用户负责（写同值也触发 `OptionSet`，noice 崩溃根因）、`virt_text`/`virt_lines` blame 与删除预览 | `loop/archive/sidebar/2026-10-16T17-33-54-sidebar-ui.md` §3.3、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §2/§5.4、`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`「M6 之后」 |
| [`./nvim/diff-and-hunks.md`](./nvim/diff-and-hunks.md) | `vim.text.diff` vs 外部 diff、`git apply --cached --unidiff-zero` 需 `\n` 结尾、xdiff 前后缀坑、词级 diff 配对、hunk 对位以真实 `git diff` 为准 | `loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §4.3、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.2/§6.3 |
| [`./lua/pitfalls.md`](./lua/pitfalls.md) | `and/or` 空值穿透、循环 require 用惰性 `require`、`local` 是保留字、`__index` 漏设、uv 回调需 `vim.schedule_wrap` | `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §6.3、`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` §6、`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` D11/D16 |
| [`./testing/headless-nvim.md`](./testing/headless-nvim.md) | TAP runner + 阻塞式 `helpers.wait`、`screenstring` 屏幕单元格断言、headless `:helptags` 真写文件、工具钉版本到 `deps/`、`LUA_FILES` 用 `git ls-files`（未 `git add` 的新文件漏检）、heredoc ~7KB 截断、`pcall` 隔离使回调内断言不传播 | `loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md` §3–§5/§7、`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` §6.7 |
| [`./decisions.md`](./decisions.md) | `D1`–`D48` 一行摘要 + 指向来源文档的索引（ADR 摘要，不复制论证） | `loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` §4、`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §2 |

## 迁移后的实况修正

以下事实在 2026-10-16 的 `loop/` 迁移后已经变化，知识文档正文按「原文抽取」保留旧值，
以这里为准：

- `.luacheckrc` 的 `exclude_files` 从 `impl/**` 改为 `loop/**`（`impl/` 目录已删除）。
- `LUA_FILES` 的文件集在 2026-10-16 之后加了 `'plugin/*.lua'`：现在是
  `git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua' 'plugin/*.lua'`，
  结论不变：未 `git add` 的新文件不会被检查。
- 命令注册从 `plugin/vcssign.vim` 改为 `plugin/vcssign.lua`（Neovim 启动时会 source
  `plugin/**/*.lua`）；知识文档正文里出现旧文件名的以这里为准。
- 计划文档的引用路径从早期的 `impl` 目录改为 `loop/archive/` 下按模块归档的文档
  （`00`–`08` 与路径的对照表见 [`../archive/README.md`](../archive/README.md)）。

## M7 追加（`08`）

2026-10-19 的性能/架构审查（[`08`](../archive/perf/2026-10-19T11-33-42-m7-performance-review.md)）
又实测出一批与实现强绑定的事实，作为**追加小节**写在对应文档末尾（正文仍旧原文抽取、不改写）：

| 文档 | 追加内容 |
|---|---|
| [`./lua/pitfalls.md`](./lua/pitfalls.md) | `x and nil or y` 永远得不到 `nil`（「全员失效」被静默降级成一个文件）；局部 `ok` 遮蔽断言函数 |
| [`./nvim/libuv-and-vim-system.md`](./nvim/libuv-and-vim-system.md) | `stdin = true` 才可写（漏了静默失败）；流式回调收尾给 `nil`；非递归 watch 的 `filename` 可能是目录名；`recursive` 是标志而非句柄数（S1 实测） |
| [`./vcs/git-output-formats.md`](./vcs/git-output-formats.md) | `--porcelain=v2 -z` 记录形状与忽略目录折叠；`cat-file --batch` 每个进程只解析一次 index、正文需去 CRLF |
| [`./testing/headless-nvim.md`](./testing/headless-nvim.md) | 进程预算回归 spec（`proc_budget_spec`）、`spawns(fn, only_cwd)` 必须限定仓库、`autocmds.setup()` 缺失会让 autocmd 断言假通过 |


## 速查

- **写 sign / extmark 前**：读 [`./nvim/signs-and-extmarks.md`](./nvim/signs-and-extmarks.md)
  （priority 与 `'signcolumn'` 的两个反直觉点）。
- **起外部进程或监听文件前**：读 [`./nvim/libuv-and-vim-system.md`](./nvim/libuv-and-vim-system.md)。
- **解析 VCS 输出前**：读 [`./vcs/git-output-formats.md`](./vcs/git-output-formats.md) 与
  [`./vcs/svn-output-formats.md`](./vcs/svn-output-formats.md)（含实测字节流样本）。
- **加用例前**：读 [`./testing/headless-nvim.md`](./testing/headless-nvim.md)。
- **想知道某个决定为什么**：先查 [`./decisions.md`](./decisions.md) 的 `D<n>`，再按索引跳归档文档。
