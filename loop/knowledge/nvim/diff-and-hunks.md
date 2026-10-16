# diff 与 hunk（内置 diff 语义 + 补丁应用）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §4.3、
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.2（及 §6.3 里 diff 相关的几条坑）。
> 原文抽取，未做改写。

**要点**：比对走 `vim.text.diff({a}, {b}, { result_type = 'indices' })`（纯函数、无进程），
`a` = 基线文本、`b` = 缓冲区文本；`indices` 是 1 基 `{start_a, count_a, start_b, count_b}`，
**两端可能带公共前后缀**，画行内区间前要先剪掉；`vim.text.diff` **只收字符串**（传 table 报
`bad argument #1`）；补丁走 stdin（`git apply --cached --unidiff-zero -`），**patch 必须以 `\n` 结尾**。

---

*来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md`，原文 `### 4.3 stage / unstage / commit`*（标题层级已下移一级）

#### 4.3 stage / unstage / commit

- `stage`: `git add -- <files>`（`--` 分隔防路径歧义）
- `unstage`: `git restore --staged -- <files>`（需 git ≥ 2.23）。**实现选择**：不做版本号解析，
  首次失败且错误匹配 `not a git command`（旧版 git 无 `restore` 子命令，实测文案 `git: 'restore' is not a git command.`）
  或 `unknown option`（未来选项变动）时，记住标记并自动改用 `git reset HEAD --` 重试一次。
  ⚠ 只匹配 `unknown option` 是错的——代码审查发现这是**死分支**，已在本次修复。
- `commit`: `git commit -m <msg> -- <files>`（初版不做 `--amend`）

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §5.2 git 行为（→ D41 / D42）`*（标题层级已下移一级）

#### §5.2 git 行为（→ D41 / D42）

**`git show :<rel>` 各场景**（原文照抄）

| 场景 | 退出码 | 输出 / 报错 |
|---|---|---|
| 已暂存（与工作树不同） | 0 | 暂存区内容 |
| 未跟踪 | 128 | `fatal: path 'u.txt' exists on disk, but not in the index` |
| `git rm -f --cached` 之后 | 128 | 同上 |
| 空仓库（unborn HEAD）`git show :<rel>` | 0 | 暂存内容（**无提交也 OK**） |
| 空仓库 `git show HEAD:<rel>` | 128 | `fatal: invalid object name 'HEAD'.` |
| 冲突文件 `git show :<rel>` | 128 | `fatal: path 'c.txt' is in the index, but not at stage 0` + `hint: Did you mean ':1:c.txt'?` |

- 冲突可用 `git show :1:<rel>`/`:2:`/`:3:`（code 0，base/ours/theirs）；`git ls-files -u -- <rel>` 列出三 stage。
- `git ls-files --error-unmatch -- <rel>`：已跟踪 → code 0，out `"f.txt\n"`；未跟踪/不存在 → code 1，
  err `error: pathspec 'u2.txt' did not match any file(s) known to git` + `Did you forget to 'git add'?`。
- **`git apply --cached --unidiff-zero -`（stdin，无临时文件）**：零上下文补丁（`@@ -1 +1,2 @@`）**必须加 `--unidiff-zero`**，
  否则 `error: patch failed: f.txt:1` / `error: f.txt: patch does not apply`；加了 → code 0，`git show :f.txt` 变 `a\nb\n`，
  `git diff --cached` 含该 hunk，工作树不变。**补丁结尾缺 `\n` → code 128 `error: corrupt patch at <stdin>:5`**。
  末尾 `-` 可省（无补丁参数时 git 默认读 stdin），但显式写更清楚。
- `git apply -R --unidiff-zero -`（工作树方向）：code 0，工作树 `a\nb\n` → `a\n`，`git diff` 显示反向 hunk。
- **`git blame --line-porcelain -L 1,3 -- <file>` 首行**：`<40hex sha> <orig_lineno> <final_lineno> <num_lines>`
  （第 3 个字段=**最终行号**）；随后 `author` / `author-mail` / `author-time`（Unix 秒）/ `summary` / `filename` /
  `previous` / `boundary`，末行以 **TAB** 开头是源码内容。一次 call 只能对齐一种行号，按 4 行一组读。
  工作树已改未提交的行 sha 全 0（`0000…0000`），`author Not Committed Yet`，`summary Version of f.txt from f.txt`。
- `git status --porcelain=v1 -z -- <rel>`：未跟踪 → `"?? u.txt\0"`（**NUL 结尾**，无换行）；已暂存 → `"MM f.txt\0"`；按 `\0` 切分，前 2 字符=状态。
- `git rm --cached`（不带 `-f`）在「暂存内容与工作树和 HEAD 都不同」时会失败（code 1，提示 `use -f`）。
