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
- 命令族现状（`cli.lua` + `plugin/vcssign.lua`）见同文档 §3。
- 「不做 `:Gitsigns` 那类命令族」是有意差异，理由见
  `loop/knowledge/ecosystem/prior-art.md`；本文件里的 `setqflist` / `select_hunk` 等正是当时
  列入 backlog、「等用户点名」的那些。

---

## `08` §5–§6 的遗留（M7 明确不做，留档）

M7 结束时还剩三件，都写在 [`08`](../../archive/perf/2026-10-19T11-33-42-m7-performance-review.md) 的
§5「不是不想优化，而是不值得」与 §6「还没做的」里：

- **`P1-4` `repo_manager.get_by_path` 的线性扫描**：仓库数是各位数，单次 `0.032 ms`，
  10 个 root 也才 `0.25 ms`。真要动就顺手做，不值得单独立项。
- **`S2` 多目标合并**：`svn info a b c` 一次 54.2 ms（单目标 82.5 ms）、`git ls-files -- a b c` 也行，
  可以把 N 次「这个文件在不在版本控制里」压成 1 次。它是「批量问状态」的**过渡步**，
  而 `status` 视图（M7 4a）已经把这个问题整体解决，所以只在需要逐个路径判定时才值得做；
  注意 `git ls-files --error-unmatch` 只要有一个未跟踪就整体非零。
- **`S3` svn `apply_patch` 的临时文件**：svn 1.14.5 不吃 stdin（`svn.EXE: invalid option:`），
  写临时文件是**能力差异**，不是缺陷——不要「顺手统一成 stdin」。
