# 01 · VCS 抽象层与 git / svn 适配器（P0）

> **⚠ M6 起部分内容已过时**：`status_type.lua`（§2 的统一状态枚举）在 M6 Step 1（`080379c`）随侧边栏
> 一起退役 —— 现在没有「文件状态列表」这一层，适配器只提供五个**交互原语**（`show` / `is_tracked` /
> `blame` / `apply_patch` / `revert` + `VcsCaps`，接口见 `07-signs-in-signcolumn.md` §3.1）。§2–§5 的枚举与
> `status` 解析链保留为 M1 的记录；§6 的适配器契约（错误优先回调、回调在主循环）仍然有效。

> 优先级最高的原因：一切上层能力（缓存、侧边栏、动作）都建立在
> 「给定路径 → 找到仓库 root → 拿到归一化的状态列表」这条数据通路上。
> 本层完成后即可独立验收，不受 UI 进度影响。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `lua/vcssign/status_type.lua` | 统一状态枚举 + 每种状态的默认符号 / 高亮组 / sign 优先级 |
| `lua/vcssign/vcs/base.lua` | `VcsSystem` 接口（含 emmylua 元类型定义） |
| `lua/vcssign/vcs/git.lua` | git 适配器 |
| `lua/vcssign/vcs/svn.lua` | svn 适配器 |
| `lua/vcssign/vcs/init.lua` | registry：系统注册表 + `detect(path)` 活跃系统探测 |

## 2. 统一状态枚举（status_type.lua）

以 oil-vcs-status `constant/status.lua` 为基础精简（去掉初版用不到的 copied / upstream 全家桶中不产生于本地命令的部分），**两个状态域**：

```lua
---@enum vcssign.StatusType
-- 文件域（工作区 / 暂存区共用一族的「种类」，域由字段区分）
M.StatusType = {
    modified   = "modified",
    added      = "added",
    deleted    = "deleted",
    renamed    = "renamed",
    untracked  = "untracked",
    ignored    = "ignored",
    typechange = "typechange",   -- git: T
    conflicted = "conflicted",   -- git: U / svn: C
    replaced   = "replaced",     -- svn 特有: R
    missing    = "missing",      -- svn 特有: !（版本化但文件丢失）
    switched   = "switched",     -- svn 特有: S
    external    = "external",    -- svn 特有: X（外部定义）
    obstructed = "obstructed",   -- svn 特有: ~
}

-- 文件的两个域，字段名用 git porcelain 自己的术语：
--   index    = X 列（暂存区）
--   worktree = Y 列（工作区）
-- 任一域都可能为 nil：只暂存的改动没有 worktree 状态，untracked 没有 index 状态，
-- svn 则根本没有 index 域。
---@class vcssign.FileStatus
---@field index    vcssign.StatusType?  # git X 列（暂存区）；svn 恒 nil
---@field worktree vcssign.StatusType?  # git Y 列 / svn 第 1 列
---@field orig_path string?             # git 重命名源 / svn 历史
```

> **实现修正（本次落地）**：原计划这两个字段叫 `upstream` / `local`。`local` 是 Lua 保留字，
> **无法用点号访问**（`status.local` 直接是语法错误，已实测），只能写成 `status['local']`。
> 因此改用 git porcelain 文档自身的说法 `index` / `worktree`：可点访问、语义更准确
> （`upstream` 在 git 语境里通常指远端跟踪分支，容易误解）。
> 落地于 `lua/vcssign/status_type.lua`，由 `test/status_type_spec.lua` 钉住不变量。

配套默认表（结构与 oil-vcs-status `config.status_symbol / status_hl_group / status_priority` 三件套一致，但由 status_type 集中持有默认值，config 可覆盖）：

```lua
M.default_symbol = {      -- 双 sign 位时，符号取 status → symbol
    modified = "M", added = "A", deleted = "D", renamed = "R",
    untracked = "U", conflicted = "!", ...
}
M.default_hl_group = {   -- VcssignModified 等默认 default link Diff* / Diagnostic*
    modified = "VcssignModified", ...
}
M.default_sign_priority = { modified = 10, added = 20, deleted = 30, ... }
```

> sign 列宽度不足时，`sign_priority` 大者显示（oil-vcs-status 同款策略；signcolumn 默认 `auto:2`，两位正好对应 index/worktree）。

## 3. VcsSystem 接口（vcs/base.lua）

照 vcs-helper `meta/systems.lua` 的「接口即注释类型」风格，修正其缺陷（所有方法显式接收 `root`，不用 cwd）：

```lua
---@class vcssign.VcsSystem
---@field name string
---@field keyfile string                     # 兜底探测用: ".git" / ".svn"
---@field capabilities vcssign.VcsCaps        # 见 04 的能力声明

-- 探测 root。优先命令（异步权威值），同步兜底为关键字扫描。
-- 同步兜底要求: .git 为目录、或 .git 为文件(worktree, 内含 "gitdir: ...") 时都要认出。
---@field find_root_sync fun(path: string): string?
---@field get_root_async fun(path: string, cb: fun(err: string?, root: string?))
-- 元数据目录（可选）：Repo 要监听的是它，而不是 `<root>/<keyfile>`。
-- git worktree/submodule 的 `.git` 是**文件**且真 index 在仓库外，只能由这里给出。
---@field metadata_dir? fun(root: string): string?

-- 基线指纹（可选，M7 P0-4）：回答「决定 show(rev, rel) 结果的那份元数据现在是什么」。
-- 只用于渲染短路——值没变就跳过整趟重读。零进程（uv.fs_stat 的 ino/size/mtime），
-- 不查 status、不算内容 hash。拿不到或不确定就返回 nil，调用方退回「每次都重读」，
-- 所以没有这个钩子的适配器行为与以前完全一致。
-- git: `.git/index` + `HEAD` + `HEAD` 指向的分支文件（提交只改后者，只 stat HEAD 会漏）；
-- svn: `.svn/wc.db`（update/switch/revert/add/commit 都会重写它）。
---@field baseline_stamp? fun(root: string): string?

-- 拉取状态，归一化为 FileStatus 表。
-- 注意: 必须以 root 为基准拼绝对路径（修正 vcs-helper 的 getcwd 缺陷）。
---@param root string
---@param callback fun(err: string?, entries: vcssign.StatusEntry[]?)

---@class vcssign.StatusEntry
---@field path string             # 绝对路径, vim.fs.normalize 后
---@field rel_path string         # 相对 root
---@field status vcssign.FileStatus
```

git / svn 各自再实现动作方法（能力见 04，git 最多）：

```
stage(root, files, cb) / unstage(root, files, cb)        -- git only
commit(root, files, msg, cb)  -> cb(err, info)           -- info: 提交摘要
 diff(root, file, opts, cb)   -> cb(err, text)           -- opts: { cached?: boolean }
```

> **实现修正（本次落地）**：所有回调统一为 **错误优先** `cb(err, ...)`。
> 计划原稿里 `get_root_async` 写成 `cb(root)`，`detect_async` 写成 `cb(system, root, err)`，
> 既与其它方法（`status`/`commit`/`diff`）不一致，也最容易写出 `local err, root = ...` 这种错位取值
> ——本次实现过程中就真踩了一次（测试里 5 个用例同时莫名失败）。现在统一为：
> `get_root_async(path, cb)` → `cb(err, root)`；`detect_async(path, cb)` → `cb(err, system, root)`。
> `diff` 多一个 `opts` 形参，因为 svn 无暂存区、git 需要区分 diff 目标（工作区 vs `--cached`）。
>
> **另一条契约（供 M2 注意）**：并非所有回调都是异步的。能力不支持（`base.unsupported`）、
> 参数校验失败（空文件列表）都是**同步**调 `cb`；`vim.system` 路径才是异步。
> 因此 M2 的「调用后再置 `is_updating` / `is_dirty`」写法会被同步回调打穿，
> 要么先置标志再调用，要么统一用 `vim.schedule` 延后回调。

> **M7 追加**：`baseline_stamp(root)` 与 `metadata_dir(root)` 都是**可选**钩子，都不进 `capabilities`
> ——它们的语义是「能回答就回答」，不是「支持/不支持某个动作」：`metadata_dir` 服务 fs 监听（D20），
> `baseline_stamp` 服务渲染短路（08 P0-4）。拿不到就不回答，上层自然退回旧行为。

**base.lua 里同时写死「能力接口默认实现」**：不支持的调用返回 `"capability unsupported: <name>"` 错误，防止子模块漏实现导致 nil 调用。

## 4. git 适配器要点（vcs/git.lua）

### 4.1 root 检测

- 异步权威：在 `path` 目录下执行 `git rev-parse --show-toplevel`（git 能正确处理 worktree、`.git` 为文件的情况；vcs-helper 的纯 keyfile 扫描处理不了 worktree）。
- 同步兜底：向上扫描 `.git`（目录 **或文件** 都认）；扫到文件时读 `gitdir: ...` 指向再判断，拿不准就返回 nil、等异步权威值。
- **实现修正（代码审查后）**：兜底 marker 必须真的像一个仓库：`.git` 为目录时要求它里面有 `HEAD`；
  `.git` 为文件时要求 `gitdir:`（相对路径按所在目录解析）目标**存在且是目录**。
  否则「main repo 已被删除的 worktree 残留」会被当成合法 root，还会把
  「这不是仓库」这个正确结论永久吞掉（见 §6 的确定性否定规则）。

### 4.2 状态获取（对照参考修正三处硬伤）

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
> 中文字节直接原样传输。样本见 `impl/init/06-todo.md` 附录 A1。
> 另：`--literal-pathspecs` 也用在 stage/unstage/commit 上，避免文件名里的 glob 元字符被展开。

### 4.3 stage / unstage / commit

- `stage`: `git add -- <files>`（`--` 分隔防路径歧义）
- `unstage`: `git restore --staged -- <files>`（需 git ≥ 2.23）。**实现选择**：不做版本号解析，
  首次失败且错误匹配 `not a git command`（旧版 git 无 `restore` 子命令，实测文案 `git: 'restore' is not a git command.`）
  或 `unknown option`（未来选项变动）时，记住标记并自动改用 `git reset HEAD --` 重试一次。
  ⚠ 只匹配 `unknown option` 是错的——代码审查发现这是**死分支**，已在本次修复。
- `commit`: `git commit -m <msg> -- <files>`（初版不做 `--amend`）

## 5. svn 适配器要点（vcs/svn.lua）

### 5.1 root 检测

- 异步权威：`svn info --show-item wc-root`（svn ≥ 1.9；拿到的是工作副本根）。**实现选择**：不预先跑
  `svn --version --quiet`，而是在 `--show-item` 报 `invalid option` / `unknown option` 时才回退到 marker 扫描结果
  并 `vim.notify` warn 一次（懒探测，省一次进程）。
- 同步兜底：向上扫描 `.svn` **目录**（svn 不存在 `.git`-为-worktree-文件那种情况）。

### 5.2 状态获取

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
| `I` | ignored（`svn status --no-ignore` 时出现；初版默认不带 `--no-ignore`，不采集） |
| 列7 `C` | conflicted（tree conflict，优先于列 1） |
| 列2 `M`（列1 为空格） | modified（纯属性修改） |
| 列2 `C` | conflicted（属性冲突） |
| 列5 `S`（其它均为空） | switched（降级为兼底标记） |

- svn 无暂存区 → `index = nil`（永远只有 worktree 域；侧边栏 git 双列 / svn 单列，见 03）。
- 列 3 `L`（加锁）/ 列 4 `+`（带历史）/ 列 6 `K` 等不产生条目，仅作为列 1 的补充信息忽略。

### 5.3 svn 动作能力

```lua
capabilities = { diff = true, commit = true, stage = false, unstage = false }
```

- `commit`: `svn commit -m <msg> -- <files>`（注意 svn commit 是**递归**到 `path` 下的，UI 传文件级条目时天然正确）。
- `diff`: `svn diff -- <file>`（svn diff 支持 `--`）。

## 6. registry（vcs/init.lua）

```lua
---@param path string
---@return vcssign.Detection?   # { system, root?, get_root_async }
function M.detect(path)

-- 异步权威版：marker 扫描定系统，命令给 root；扫描全空时按优先级逐个探测系统。
---@param cb fun(err: string?, system: vcssign.VcsSystem?, root: string?)
function M.detect_async(path, cb)
```

- 逐系统调 `find_root_sync`；**同一个 path 上多个系统都有 root 时取「root 路径更深（更长）」者**（嵌套仓库：外层 git + 内层 svn → 当前文件在内层 svn 时应选 svn；当前文件在外层 git 区时选 git）。
- `M.get(name)` 按名字取单个系统，`M.MODULES` 是名字→模块路径的注册表。
- `detect_async` 的回落规则（审查后收紧）：marker 扫描命中但命令失败时，**只有**失败属于
  「暂态/环境问题」（如 `safe.directory`、超时、命令缺失）才用 marker 结果兼底；
  若错误是**确定性否定**（`not a git repository` / `is not a working copy` / `E155007`），
  则必须如实报告「不是仓库」，否则会把 stale marker 复活成幽灵仓库。
- `setup()` 支持用户 `systems = { "git", "svn" }` 重排序 / 禁用某系统（config schema 字段，见 00 §3 config.lua）；
  `get_systems()` 每次读 config，改配置立即生效（不做启动时快照）。
- 新增 VCS = 新写一个模块实现 base 接口 + 注册到列表，**不改任何上层代码**（本层验收的唯一硬指标）。

## 6.1 `exec.run` 的超时定时器（M4 实测修正）

计划里的顺序是「先 `vim.system`，再建并武装超时定时器」。实测发现 **`vim.system` 的退出回调可能在本函数返回之前就跑**
（立刻失败的进程，例如 `cwd` 不存在），于是那次 `finish` 看到 `timer = nil`（还没有定时器可关），
定时器随后被武装、却再也没人关它——直到 15s 后超时回调发现自己 `finished` 才自我关闭。
期间它是一个活着的、已武装的 handle（`autocmds_spec` 的 `VimLeavePre` 用例抓到的就是这个）。

改为**先建定时器再 spawn**（`proc` 预先声明为局部变量，超时回调里判空后再 `kill`）：`finish` 无论如何都能关掉它。
`test/exec_spec.lua` 的 7 个用例（含超时与「0 表示不限时」）在改动后仍全绿。

## 7. 验收标准

1. 在 `temp/git-repo`（含 untracked / staged modify / worktree modify / staged delete / rename / 子目录路径）上：`git.status(root, cb)` 的 entries 覆盖以上所有状态且 path 全部为正确绝对路径（含空格 + 中文文件名用例）。
2. 在 `temp/svn-repo`（含 modified / added / deleted / unversioned / missing / property-modified / replaced / 子目录）上同上；
   另断言 `rel_path` 是**相对 root** 而非相对 cwd（回归 vcs-helper 的 getcwd 缺陷）。
3. worktree：在 `temp/git-repo` 的 `git worktree add` 产物目录中探测 root 成功（vcs-helper 模式在此场景必失败，作为回归用例）。
4. 嵌套仓库：`temp/nested/`（git 仓库内含 svn 工作副本）中，探测随传入 path 正确切换系统。
5. 两个适配器对未实现能力（svn stage）返回明确错误字符串而非抛 nil 异常。

**落地状态：已全部完成并通过**，共 44 个 spec 用例（`scripts/run_tests.sh`）：
`test/status_type_spec.lua`、`test/config_spec.lua`、`test/vcs_git_spec.lua`（15）、`test/vcs_svn_spec.lua`（15）、
`test/vcs_registry_spec.lua`。未覆盖项：`stage`/`unstage`/`commit` 的**写操作**未测（会在 fixture 上留下副作用），
留到 M5 的副本仓库 spec（`temp/.work/<spec>`）里做。
