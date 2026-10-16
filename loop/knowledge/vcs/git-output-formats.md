# git 输出格式与调用约定（实测）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §4 与
> `loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` 附录 A1。原文抽取，未做改写。

**要点**：状态一律用 `git status --porcelain=v1 -z --untracked-files=all` 的 NUL 分隔字节流解析
（rename 占两段路径）；必须设 `core.quotepath=false`、`LC_ALL=C`、`MSYS=noglob`（Windows）；
读操作带 `--no-optional-locks`；root 用 `rev-parse --show-toplevel`，worktree/submodule 的
`.git` 文件是 `gitdir: <path>` 文本，要再解析一层。

---

*来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md`，原文 `## 4. git 适配器要点（vcs/git.lua）`*（标题层级已下移一级）

### 4. git 适配器要点（vcs/git.lua）

#### 4.1 root 检测

- 异步权威：在 `path` 目录下执行 `git rev-parse --show-toplevel`（git 能正确处理 worktree、`.git` 为文件的情况；vcs-helper 的纯 keyfile 扫描处理不了 worktree）。
- 同步兜底：向上扫描 `.git`（目录 **或文件** 都认）；扫到文件时读 `gitdir: ...` 指向再判断，拿不准就返回 nil、等异步权威值。
- **实现修正（代码审查后）**：兜底 marker 必须真的像一个仓库：`.git` 为目录时要求它里面有 `HEAD`；
  `.git` 为文件时要求 `gitdir:`（相对路径按所在目录解析）目标**存在且是目录**。
  否则「main repo 已被删除的 worktree 残留」会被当成合法 root，还会把
  「这不是仓库」这个正确结论永久吞掉（见 §6 的确定性否定规则）。

#### 4.2 状态获取（对照参考修正三处硬伤）

命令：

```
git --no-pager --no-optional-locks --literal-pathspecs \
    -c core.quotepath=off -c gc.auto=0 \
    status --porcelain=v1 -z --untracked-files=all
```

相对 vcs-helper `systems/git.lua` 的修正：

1. **`--porcelain=v1 -z`**：NUL 分隔的机器可读格式。含空格 / 中文 / 引号的路径直接按整段读取，**无需** `read_quoted_string` 反引号解码（C 风格引号转义仅在非 `-z` 的 porcelain 出现）。重命名条目格式：`XY <new>\0<old>\0`。
2. 环境强制 `LC_ALL=C`（gitsigns `git/cmd.lua` 的经验，防本地化输出污染解析）；Windows 下 `MSYS=noglob CYGWIN=noglob`（防 MSYS2 改写参数）。
3. 解析循环按 `-z` 协议：`vim.split(stdout, "\0")`；若当前段匹配 `^R. `，则**下一段是 orig_path**，两段一起消费。

X/Y 字符 → `StatusType` 映射表（参考 oil-vcs-status `systems/git.lua` 的 `STATUS_MAP` / `UPSTREAM_STATUS_MAP`）：

| 域 | 字符 → 类型 |
|----|-------------|
| index (X) | `M→modified A→added D→deleted R→renamed C→renamed T→typechange .→nil ?→untracked !→ignored U→conflicted` |
| worktree (Y) | 同上 + `.`→nil |

两个特殊情形单独处理（不查表）：`??` → 仅 `worktree=untracked`（否则 X 列也会被当成 untracked），
`!!` → 仅 `worktree=ignored`；unmerged 组合 `UU/AU/UD/UA/DU` 与 `AA/DD` 一律两域都是 `conflicted`。
`C`（copied）枚举里没有对应项，归入 `renamed`（默认 `status.renames` 不检测副本，实际很少出现）。

> **实测校正**：在 `temp/git-repo` 上用 `-z` 抓到的真实字节流已验证上述全部假设：
> rename 确实是「新路径 + orig_path」两段相邻记录；`-z` 下**不会**出现引号转义（因此完全不需要解码）；
> 中文字节直接原样传输。样本见 `loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` 附录 A1。
> 另：`--literal-pathspecs` 也用在 stage/unstage/commit 上，避免文件名里的 glob 元字符被展开。

---

*来源：`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`，原文 `### A1 · git `status --porcelain=v1 -z --untracked-files=all`（`temp/git-repo`）`*（标题层级已下移一级）

#### A1 · git `status --porcelain=v1 -z --untracked-files=all`（`temp/git-repo`）

NUL 分隔（下文以换行代替 NUL 展示；中文路径按 UTF-8 原样传输，无需引号解码）：

```
 M base.txt
 D old.txt
 R  renamed.txt
 文件 名.txt          ← rename 条目的第二段（orig_path），紧跟新路径段之后，整体消费
 A  staged-add.txt
 AM staged-mod.txt
 ?? new.txt
 ?? untracked 名 .txt
```

要点确认：
- rename 记录是**连续两段**（新路径 + orig_path），解析循环必须按 01 §4.2 的「双段消费」处理；
- `core.quotepath` 引号转义**不会出现**在 `-z` 输出中（计划 D3 验证成立）；
- 状态域实际形态：` M`（local M）、` D`（local D）、`R `（upstream R）、`A `、`AM`（upstream A + local M）、`??`（untracked）。

冲突仓库 `temp/git-repo-conflict`：`UU conflict.txt`（upstream U + local U → conflicted）。

`git rev-parse --show-toplevel`（`temp/git-worktree`）输出：`D:/Developer/nvim-plugins/vcssign/temp/git-worktree` —— 正斜杠绝对路径，直接可作 root 键（统一 `vim.fs.normalize`）。
