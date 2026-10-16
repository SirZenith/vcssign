# backlog：命令与动作（`commands/`）

**状态**：`[ ] 未开始`

**出处**：`loop/archive/commands/2026-10-16T17-33-54-commands-and-actions.md` §7.3。

**为什么记下来**：M4 落地 `:Vcssign` 命令族与动作层时，这几项都想过、也都判断「本里程碑不做」。
理由写在下面各条里（不是「没时间」，而是每种都需要额外的解析或平台分支）。

---

## 一、backlog（本里程碑不做）

> 原文（`04 §7.3`），逐条保留：

- `commit.message_input = "buffer"`：临时缓冲区写提交消息（gitsigns `actions/commit.lua` 是参考）。
- 多选/整组 stage（`:Vcssign stage` 目前一次一个文件）。
- diff 的左右窗模式（worktree vs HEAD 并排）、word diff。
- `:Vcssign` 的路径参数补全（需要 `-complete=file` 之外的自定义实现）。
- 未跟踪文件的 `d`：`git diff HEAD` 对 untracked 永远是空，用户想看的是「新文件全文」。
  实现路径是 `git diff --no-index`（Windows 上 `/dev/null` 的等价物要单独处理），不是一行能改对的。
- 补全在带范围/缩写前缀时（`:1,5Vcssign st`）返回空集：`cmdline` 的形态比 `Vimcssign <word>` 多，需要更细的解析。

### 逐条验收要点

| 项 | 验收要点 |
|---|---|
| `commit.message_input = "buffer"` | 新增配置项（默认仍是 `input`）；`buffer` 时开临时 scratch buffer、`q`/`<Esc>` 可取消、写回后清理，且 `:q!` 不丢未提交消息的提示明确 |
| 多选 / 整组 stage | 视觉模式选中多行或整组 hunk 后 stage；`stage` 支持多个文件参数；部分失败时的报告策略明确（逐个报错，不中断） |
| 并排 diff / word diff | 新增左右窗模式（`worktree` vs `HEAD`）；word diff 复用 hunk 行内 diff（见 `loop/knowledge/nvim/diff-and-hunks.md`） |
| 路径补全 | 用 `-complete=customlist` + 自定义实现；保留 `-complete=file` 的既有行为不回归 |
| 未跟踪文件的 `d` | 用 `git diff --no-index`；Windows 上 `/dev/null` 的等价物单独处理并有用例 |
| 带范围/缩写前缀的补全 | `:1,5Vcssign st` 这类 `cmdline` 形态返回正确候选；解析比 `Vimcssign <word>` 复杂，需专门用例 |

## 二、相关

- 动作层的分派规则（按 `VcsCaps` 能力分派）见
  `loop/archive/commands/2026-10-16T17-33-54-commands-and-actions.md` §2。
- 命令族现状（`cli.lua` + `plugin/vcssign.vim`）见同文档 §3。
- 「不做 `:Gitsigns` 那类命令族」是有意差异，理由见
  `loop/knowledge/ecosystem/prior-art.md`；本文件里的 `setqflist` / `select_hunk` 等正是当时
  列入 backlog、「等用户点名」的那些。
