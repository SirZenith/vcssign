# 01 · VCS 抽象层与 git / svn 适配器（P0）

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

-- git 侧的字段：
---@class vcssign.FileStatus
---@field upstream vcssign.StatusType?  # 暂存区（git X 列）；svn 恒 nil
---@field local    vcssign.StatusType   # 工作区（git Y 列 / svn 第1列）
---@field orig_path string?             # git 重命名源 / svn 历史
```

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

> sign 列宽度不足时，`sign_priority` 大者显示（oil-vcs-status 同款策略；signcolumn 默认 `auto:2`，两位正好对应 upstream/local）。

## 3. VcsSystem 接口（vcs/base.lua）

照 vcs-helper `meta/systems.lua` 的「接口即注释类型」风格，修正其缺陷（所有方法显式接收 `root`，不用 cwd）：

```lua
---@class vcssign.VcsSystem
---@field name string
---@field keyfile string                     # 兜底探测用: ".git" / ".svn"
---@field capabilities vcssign.VcsCaps        # 见 04 的能力声明
local VcsSystem = {}

-- 探测 root。优先命令（异步权威值），同步兜底为关键字文件扫描。
-- 同步兜底要求: .git 为目录、或 .git 为文件(worktree) 时都要认出。
---@param path string
---@return string? root            # 同步兜底结果，立即可用
---@return fun(cb: fun(root: string?)) get_root_async   # 命令式权威探测

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
stage(root, files, cb) / unstage(root, files, cb)     -- git only
commit(root, files, msg, cb)
diff(root, file, cb)                                 # 见 04：diff 动作
```

**base.lua 里同时写死「能力接口默认实现」**：不支持的调用返回 `"capability unsupported: <name>"` 错误，防止子模块漏实现导致 nil 调用。

## 4. git 适配器要点（vcs/git.lua）

### 4.1 root 检测

- 异步权威：在 `path` 目录下执行 `git rev-parse --show-toplevel`（git 能正确处理 worktree、`.git` 为文件的情况；vcs-helper 的纯 keyfile 扫描处理不了 worktree）。
- 同步兜底：向上扫描 `.git`（目录 **或文件** 都认）；扫到文件时读 `gitdir: ...` 指向再判断，拿不准就返回 nil、等异步权威值。

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
| upstream (X) | `M→modified A→added D→deleted R→renamed T→typechange .→nil ?→untracked !→ignored U→conflicted` |
| local (Y) | 同上 + `.`→nil |

### 4.3 stage / unstage / commit

- `stage`: `git add -- <files>`（`--` 分隔防路径歧义）
- `unstage`: `git restore --staged -- <files>`（需 git ≥ 2.23；启动时探测 `git restore --help` 退出码或 `git --version`，旧版回退 `git reset HEAD --`）
- `commit`: `git commit -m <msg> -- <files>`（初版不做 `--amend`）

## 5. svn 适配器要点（vcs/svn.lua）

### 5.1 root 检测

- 异步权威：`svn info --show-item wc-root`（svn ≥ 1.9；拿到的是工作副本根）。启动时一次 `svn --version --quiet` 探测，`<1.9` 则永久回退兜底并 warn 一次。
- 同步兜底：向上扫描 `.svn` **目录**（svn 的 `.git`-为-worktree-文件的情况不存在，可直接用 vcs-helper 的 `find_root_by_keyfile` 逻辑，port 成 `vim.fs.find` / `vim.fs.dirname` 循环）。

### 5.2 状态获取

命令：`svn status --ignore-externals`（初版不展示 externals 展开项，`X` 标记的外部目录本身仍显示为 external 条目）。

输出为**本地化安全**（svn 输出不受 locale 影响状态列，但保险起见仍设 `LC_ALL=C`）。列格式（svn 1.7+，第 1 列为主状态，其后 6 列属性/锁等，参考 vcs-helper `systems/svn.lua` 的正则）：

```
M      path        # 1列: item 状态
M      path        # 2列: 属性修改
?      path
!      path
A      path
D      path
R      path        # replaced
C      path        # conflicted
X      path        # external
~      path        # obstructed
S      path        # switched (第5列)
```

解析规则（**以第 1 列为主，第 2 列为属性修改补充**）：

- 正则：`^([ ADMRCX!?~S%-%d%.])` 不够稳 → 采用 vcs-helper 同款「逐列字符白名单」正则，但放宽为：先 `sub(1,1)` 取主状态 + `sub(2,2)` 判断是否 `M`（属性修改时把 `local` 补成 `modified`，主状态为空格时**只**报属性修改）。映射表：

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
| 第5列 `S` | switched（叠加为额外标记，初版可只 log 不展示） |

- svn 无暂存区 → `upstream = nil`（永远只有 local 域；侧边栏 git 双列 / svn 单列，见 03）。

### 5.3 svn 动作能力

```lua
capabilities = { diff = true, commit = true, stage = false, unstage = false }
```

- `commit`: `svn commit -m <msg> -- <files>`（注意 svn commit 是**递归**到 `path` 下的，UI 传文件级条目时天然正确）。
- `diff`: `svn diff -- <file>`（svn diff 支持 `--`）。

## 6. registry（vcs/init.lua）

```lua
---@type vcssign.VcsSystem[]
M.systems = { git, svn }        -- 注册顺序 = 嵌套时的优先级（git 优先）

---@param path string
---@return vcssign.VcsSystem? system
---@return string? root                  # 同步兜底 root（可能 nil）
---@return fun(cb) get_root_async        # 权威 root 探测（deferred）
function M.detect(path)
```

- 逐系统调 `find_root_sync`；**同一个 path 上多个系统都有 root 时取「root 路径更深（更长）」者**（嵌套仓库：外层 git + 内层 svn → 当前文件在内层 svn 时应选 svn；当前文件在外层 git 区时选 git）。
- `setup()` 支持用户 `systems = { "git", "svn" }` 重排序 / 禁用某系统（config schema 字段，见 00 §3 config.lua）。
- 新增 VCS = 新写一个模块实现 base 接口 + 注册到列表，**不改任何上层代码**（本层验收的唯一硬指标）。

## 7. 验收标准

1. 在 `temp/git-repo`（含 untracked / staged modify / worktree modify / staged delete / rename / 冲突标记未解决文件）上：`git.status(root, cb)` 的 entries 覆盖以上所有状态且 path 全部为正确绝对路径（含中文文件名用例）。
2. 在 `temp/svn-repo`（含 modified / added / deleted / unversioned / missing / property-modified）上同上。
3. worktree：在 `temp/git-repo` 的 `git worktree add` 产物目录中探测 root 成功（vcs-helper 模式在此场景必失败，作为回归用例）。
4. 嵌套仓库：`temp/nested/`（git 仓库内含 svn 工作副本）中，探测随传入 path 正确切换系统。
5. 两个适配器对未实现能力（svn stage）返回明确错误字符串而非抛 nil 异常。

（fixture 生成命令与 spec 写法见 05。）
