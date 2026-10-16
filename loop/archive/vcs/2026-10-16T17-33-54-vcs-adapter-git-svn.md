# 01 · VCS 抽象层与 git / svn 适配器（P0）

> 归档自早期计划文档 `01-vcs-adapter.md`（M0–M6 实施计划，原 `impl/` 目录）。由 2026-10-16 的 `loop/` 迁移整篇移入 `loop/archive/`，状态：**已实现、冻结**。
> 文中 `00`–`07` 的简写指的是本目录下的归档文档，对照表见 `loop/archive/README.md`；
> 被抽取到 `loop/knowledge/` 的小节在正文里只留指针。

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

**base.lua 里同时写死「能力接口默认实现」**：不支持的调用返回 `"capability unsupported: <name>"` 错误，防止子模块漏实现导致 nil 调用。

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/vcs/git-output-formats.md`
> - `loop/knowledge/nvim/diff-and-hunks.md`
>
> §4.1/§4.2 在 git 文档，§4.3（stage / unstage / commit）在 diff 文档。

---

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/vcs/svn-output-formats.md`

---

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

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/nvim/libuv-and-vim-system.md`

---

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
