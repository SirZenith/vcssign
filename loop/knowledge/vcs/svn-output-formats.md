# svn 输出格式与 `svn patch` 语义（实测）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §5、
> `loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md` 附录 A2、
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.3 与 §11 第 2 条。原文抽取，未做改写。

**要点**：`svn status` 是 7 列状态 + 第 9 列起路径，且**文件级 diff 与逐行状态混在两套输出里**；
换行/反斜杠会转义（`svn: E195012`、`CRLF` 需自己归一）；tree conflict 用 `>` 续行；
`svn` 不能从 stdin 吃补丁（必须落临时文件 + `--strip 0`）；**`svn patch` 冲突时退出码仍是 0**，
必须解析 stdout 才判定成功。

---

*来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md`，原文 `## 5. svn 适配器要点（vcs/svn.lua）`*（标题层级已下移一级）

### 5. svn 适配器要点（vcs/svn.lua）

#### 5.1 root 检测

- 异步权威：`svn info --show-item wc-root`（svn ≥ 1.9；拿到的是工作副本根）。**实现选择**：不预先跑
  `svn --version --quiet`，而是在 `--show-item` 报 `invalid option` / `unknown option` 时才回退到 marker 扫描结果
  并 `vim.notify` warn 一次（懒探测，省一次进程）。
- 同步兜底：向上扫描 `.svn` **目录**（svn 不存在 `.git`-为-worktree-文件那种情况）。

#### 5.2 状态获取

命令：`svn status --ignore-externals`（初版不展示 externals 展开项，`X` 标记的外部目录本身仍显示为 external 条目）。

输出为**本地化安全**（svn 输出不受 locale 影响状态列，但保险起见仍设 `LC_ALL=C`）。
列定义以 `svn help status` 为准（svn 1.14.5 实测抄录，**7 个状态列 + 1 个空格，路径固定从第 9 列开始**）：

| 列 | 含义 | 取值 |
|----|------|------|
| 1 | item 状态 | `' ' A C D I M R X ? ! ~` |
| 2 | 属性修改 | `' ' C M` |
| 3 | 工作副本加锁 | `' ' L` |
| 4 | 提交将产生副本（addition-with-history） | `' ' +` |
| 5 | switched / file external | `' ' S X` |
| 6 | 仓库排他锁（带 `-u`） | `' ' K O T B` |
| 7 | **tree conflict 受害者** | `' ' C` |

> **实测校正（重要）**：
> 1. **路径必须按固定列切（第 9 列起）**——svn 对空格/中文路径**不引号也不转义**，
>    `?       sp ace 名.txt` 原样输出（实测 `svn status | cat -A`），任何按空白切分的写法都会错（vcs-helper 的正则即存在此隐患）。
> 2. Windows 工作副本输出 **CRLF** 行尾、路径分隔符为 **反斜杠**（`sub2\q.txt`）→ 需 `\` → `/` 归一。
> 3. **tree conflict 会在状态行后追加一行解释文本**（如 `      >   local edit, incoming delete upon update`），
>    解析必须跳过以 `>` 开头的续行，否则会被当成条目。
> 4. `svn status <target>` 打印的是**相对 cwd** 的路径（实测 `temp\svn-repo\base.txt`）。
>    因此必须 `cwd = root` 且**不传 target 参数**，这就是计划 D5 所说的 vcs-helper getcwd 缺陷的根因。
> 5. 管道输出中**没有** `Status against revision: N` 汇总行，但解析器仍按「不认识的列字符即丢弃」的方式
>    容错（映射表自然会滤掉它）。

实现规则（**列 7 tree conflict > 列 2 属性冲突 > 列 1 主状态**，冲突一律压过其它状态）：

- 先 `local cols = line:sub(1, 7)`（先判 `line:match('^%s*>')` 跳过续行），再 `local rel = line:sub(9)`；
  不做任何正则/空白切分。映射表：

| svn 列1 | → StatusType |
|---------|--------------|
| `M` | modified（列2 也是 M 时保持 modified，`rel_path` 不变） |
| `A` | added |
| `D` | deleted |
| `R` | replaced |
| `C` | conflicted |
| `!` | missing |
| `?` | untracked |
| `X` | external |
| `~` | obstructed |
| `I` | ignored（`svn status --no-ignore` 时出现；M7 起采集，用于 `FileStatus.ignored` → D49 不给标志） |
| 列7 `C` | conflicted（tree conflict，优先于列 1） |
| 列2 `M`（列1 为空格） | modified（纯属性修改） |
| 列2 `C` | conflicted（属性冲突） |
| 列5 `S`（其它均为空） | switched（降级为兼底标记） |

- svn 无暂存区 → `index = nil`（永远只有 worktree 域；侧边栏 git 双列 / svn 单列，见 03）。
- 列 3 `L`（加锁）/ 列 4 `+`（带历史）/ 列 6 `K` 等不产生条目，仅作为列 1 的补充信息忽略。

#### 5.3 svn 动作能力

```lua
capabilities = { diff = true, commit = true, stage = false, unstage = false }
```

- `commit`: `svn commit -m <msg> -- <files>`（注意 svn commit 是**递归**到 `path` 下的，UI 传文件级条目时天然正确）。
- `diff`: `svn diff -- <file>`（svn diff 支持 `--`）。

---

*来源：`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`，原文 `### A2 · `svn status`（`temp/svn-repo`）`*（标题层级已下移一级）

#### A2 · `svn status`（`temp/svn-repo`）

```
MM      base.txt
!       missing.txt
?       new.txt
D       old.txt
A       prop.txt
R       repl.txt
```

要点确认：
- `MM` = 第 1 列 M（内容修改）+ 第 2 列 M（属性修改）—— 01 §5.2 的「列 1 主状态 + 列 2 属性补充」策略成立；
- `!`（missing）、`R`（replaced，`svn rm --keep-local` + `svn add` 制得）按预期出现；
- `svn info --show-item wc-root` 对 `svn-repo` 与 `nested/inner` 都返回正确绝对路径（svn ≥ 1.9 特性可用，D4 成立）；
- file:// 仓库 URL 形态：`file:///D:/Developer/.../temp/svn-server/trunk`（三斜杠 + 盘符，`pwd -W` 可直接生成）。
- **补充（M1 阶段）**：两处输出均为 **CRLF** 行尾；svn 路径用**反斜杠**且从**第 9 列**开始（`sub2\q.txt`、目录条目 `sub2` 与文件条目 `sub2/q.txt` 都出现）。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §5.3 svn 行为（→ D41 / D42）`*（标题层级已下移一级）

#### §5.3 svn 行为（→ D41 / D42）

- **`svn cat -r BASE f.txt`**：在已改 WC 上输出**最后一次提交内容**（`-r HEAD`、无 `-r` 同结果）。
  `-r PREV`（rev0 无前驱）→ code 1 `svn: E195012: Unable to find repository location … in revision 0`。
  未纳管文件 → code 1，err `svn: warning: W200005: '<abs path>' is not under version control` + `svn: E200009: Could not cat all targets …`。
  `-r 99` → `svn: E160006: No such revision 99`。
- **`svn blame`** 原始：未提交/修改行用 `-` 代替 rev 与 author（`     -          - MODIFIED-l1`），字段 `%6s` 版本 + 右对齐 author + 内容。
  `svn blame -r BASE <file>` 可用。**耗时：200 行纯文本 141.1 ms，`--xml` 43.9 ms（更快 → 建议解析 XML）**。
- **`svn log --xml`**：`blame --xml` 的 `<commit>` 只有 `revision`/`author`/`date`
  （schema `subversion/svn/schema/common.rnc`），**没有 `<msg>`**；commit subject 只能从
  `svn log --xml` 取。一次 `svn log --xml -r MAX:MIN -- <wc path>` 覆盖 blame 用到的所有 rev
  （WC 路径以 BASE 为 peg，默认跟随 copy 历史）；`<msg>` 里的 XML 实体需反转义，
  subject 取第一行，空 `<msg/>` 视为没有 summary。
- `svn status -- <file>`：已改 → `M       <abs path>`；未纳管 → `?       <abs path>`（首字符 `?`）。
- **`svn info -- <abs>` 的退出码就是「是否纳管」**：已纳管 → code 0；未纳管或路径不存在 →
  code 1，stderr `svn: warning: W155010: The node '<abs>' was not found.`（空行）+
  `svn: E200009: Could not display info for all targets because some targets don't exist`；
  工作副本之外 → `svn: E155007: '<abs>' is not a working copy`（1.14.5 实测；旧版写 `W155007`）。
  **实测更正**：`svn status -- <不存在的路径>` 无任何输出且 exit 0，用它判 `?` 会把不存在的路径读成「已跟踪」，
  所以 `is_tracked` 改用 `svn info`（`lua/vcssign/vcs/svn.lua`），`test/vcs_svn_spec.lua` 有对应用例。
  另：`status` 为 `!`（已纳管但磁盘丢失）的路径 `svn info` 仍 exit 0 → 仍算已跟踪。
- **`svn revert <file>`**：code 0，`Reverted '<path>'`，工作树回 BASE，status 变干净 → 可直接丢弃工作树改动。
- **`svn patch`（重点，照抄）**：
  - **stdin 不可用**：`svn patch -` / `svn patch --strip 0 -` / `--strip 1 -` 全 code 1：`svn.EXE: invalid option: `。
    svn 1.14.5 CLI **不支持**从 stdin 读补丁 → 必须写临时文件。
  - **临时文件可行**：`svn patch --strip 0 <patchfile>` → `U         f.txt`（code 0，已应用）。
    **实测（Step 9 重做：`temp/probe_svn2` 里全新 `svnadmin` 仓库 + WC，svn 1.14.5）**：`--strip 0` 下
    **git 风格头照常应用** —— `diff --git a/x b/x` / `--- a/x` / `+++ b/x` 得到 `U         x`（exit 0）；
    裸头（`--- rel`）同样应用；嵌套路径（`sub/inner.txt`）也照此。两种头都有活用例：
    `test/vcs_svn_spec.lua` 的 `BARE_PATCH`、`actions_spec` 的 svn `reset_hunk`（走 `hunk.build_patch`
    的 git 风格头 + `--reverse-diff`）。**旧文写「git 风格头在 `--strip 0` 下不成立」是把一次
    `svn add` 过但**未提交**（BASE 里还没有）的文件的实验结果当成了头风格问题** —— 那种文件无论
    哪种头都只会得到 `C` + `rejected hunk`。`--strip 1` 才会冲突（`C .`），`--strip 2` 报
    `svn: E195018: Cannot strip 2 components from 'f.txt'`。
    所以 `lua/vcssign/hunk.lua` 的 `build_patch` 只产一种头（git 风格）就够，svn 侧不需要切换风格。
  - **反向**：`svn patch --reverse-diff <file>` 可用；**把 `+`/`-` 互换的 unidiff** 也可用于丢弃一个 hunk（svn-style 与 git-style+`--strip 0` 都验证成功）。
  - **冲突不报错（反直觉）**：hunk 无法应用时 `svn patch` 仍 **退出码 0**，stdout 打 `C         f.txt` + `>         rejected hunk …`，
    并写 `<file>.svnpatch.rej`，工作树保持不变。**不能用退出码判成败**，必须解析 stdout 的 `U `/`C ` 或检查 `.rej`。
  - 偏移补丁会 fuzz 应用：`applied hunk @@ … with fuzz 1`。
