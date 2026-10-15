# 03 · 侧边栏 UI：窗口管理、渲染、高亮、按键（P2）

> 数据通路（01/02）就绪后，UI 只是「把 StatusEntry[] 画出来 + 响应按键」。
> 渲染策略大量参考 oil-vcs-status 的 extmark sign 位方案，但它是往
> oil 缓冲区画 sign，我们是**独立的侧边栏窗口 + 专属缓冲区**，窗口管理
> 是全新的一层。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `lua/vcssign/sidebar/init.lua` | 窗口/缓冲区生命周期：open / close / toggle / is_open / focus |
| `lua/vcssign/sidebar/renderer.lua` | 行文本 + extmark 渲染、排序、分组、高亮 |
| `lua/vcssign/sidebar/keymap.lua` | 窗口内按键（分派到 04 的 actions） |

## 2. 窗口管理（sidebar/init.lua）

- **每个 Repo 一个侧边栏缓冲区**，buffer name：`vcssign://<system>/<root>`（合法 bufname 转义 `:` `\` 空格）；`buftype=nofile`、`modifiable=false`、`filetype=vcssign`、`bufhidden=hide`。
- 打开方式（config：`sidebar.position`）：
  - `"right"`（默认）/ `"left"`：**实现用的是**`nvim_open_win(bufnr, enter, { split = "right"|"left", width = N })`（实测 0.12.4 支持 `split`，且不会动当前窗口及其 buffer）—计划里写的 `{ vertical = true, win = 9999 }` + `vertical resize` 那套不需要了。默认 `width = 40`。
  - `"float"`：浮动窗—**仍未实现**：schema 收下 `"float"` 但会 `log.warn` 并回落到 `"right"`（宁可说清楚，也不静默换行为）。
- 窗口选项：`signcolumn = "yes:2"`（两位状态 sign，oil-vcs-status 同款）、`number = false`、`wrap = false`、`foldenable = false`、`spell = false`、`winfixwidth = true`。
- toggle 语义：窗口开着且聚焦 → 关闭；开着但不聚焦 → 聚焦；关着 → 打开（gitsigns toggle 类命令的常见语义）。
- 关闭时**只关窗口，缓冲区按 root 复用**（重开不丢状态，直接重渲染）。
- Repo dispose（02）→ 关闭对应窗口 + `nvim_buf_delete`。

## 3. 渲染（renderer.lua）

### 3.1 数据 → 行

输入 `Repo:entries()`，输出行模型：

```lua
---@class vcssign.RenderItem
---@field entry vcssign.StatusEntry   # 分组标题行时为 nil
---@field kind "header"|"entry"
```

- **排序**：状态严重度（conflicted > missing > modified > deleted > added > renamed > untracked > ignored）→ 再按 rel_path 字典序（vcs-helper `systems/init.lua` 的排序保留，但换成两级）。
- **分组**（config：`sidebar.group_by = "status"`，可选 `"none" | "status"`，初版只有这两档；后续可加 `"directory"` 树模式，oil-vcs-status `status_tree.lua` 是现成参考）：
  - git：`Staged`（upstream 非 nil 的条目）/ `Unstaged` / `Untracked` 三组；svn（无暂存区）：无分组或按状态种类分组 —— 由 renderer 按 `system.capabilities` / upstream 域是否全 nil 自适应（svn 天然单域）。
  - 分组标题行：`── Staged ──` 样式，用 `Comment` 高亮。

### 3.2 行文本

```
<rel_path>                                  # 前导状态由 extmark sign 位承担
```

- 重命名显示 `new (from old)`；`rel_path` 超过 `width - signcol` 截断头部（`…`）。
- 状态字符**不进行文本**，全部走 sign 位 —— 与 oil-vcs-status `add_symbol_to_buffer` 的方式一致：渲染即「设置行文本 + 两个 extmark」。

### 3.3 extmark 状态位

- namespace：`nvim_create_namespace("vcssign.sidebar")`；每次重渲染 `nvim_buf_clear_namespace` 后整体重画（条目级 diff 增量更新初版不做，数据量在几百条内全量重画开销可忽略；gitsigns manager 用全量 clear+重画也验证过该策略够用）。
- 每个条目行**两个 extmark**（oil-vcs-status `add_symbol_to_buffer` 同款）：

```lua
-- upstream 位（git 才有；svn 只画 local 位）
nvim_buf_set_extmark(buf, ns, row, 0, {
    sign_text = " " .. symbol,               -- sign_text 必须 1-2 字符，取 status_type 的 symbol
    sign_hl_group = "VcssignSign" .. Camel(type),   -- e.g. VcssignSignModified
    priority = priority + 100,               -- upstream 位整体高于 local 位（列宽不足时保住）
})
-- local 位: priority = priority
```

**sign 列的实际排布（`screenstring` 实测，0.12.4）**：同色列中**priority 高的靠左**，列宽不足时**保留 priority 高的那个**。
因此 upstream 位的偏移取 `+1000`（不是示意代码里的 `+100`）：本地状态里最高的 `conflicted = 100`，`+1000` 才能保证「有 index 位就一定有 index 位」这条不变量对**所有**组合成立。
结果正好是 `git status --short` 的 XY 观感：index 在左、worktree 在右，窄列时留下的是已暂存状态。

> 单列窗口（`sidebar.single_column`）**未实现**，见 §7：`yes:2` 是侧边栏的固定形态，单列只在用户自己覆盖 `signcolumn` 时出现。


### 3.4 高亮

- 默认组（setup 时 `nvim_set_hl`，参考 oil-vcs-status 的组语义 + gitsigns 的命名习惯 `Vcssign<State>`）：

| 高亮组 | 默认链接 |
|--------|----------|
| `VcssignSignModified` / `VcssignModified` | `DiffChange` |
| `VcssignSignAdded` / `VcssignAdded` | `DiffAdd` |
| `VcssignSignDeleted` / `VcssignDeleted` | `DiffDelete` |
| `VcssignSignUntracked` | `DiagnosticWarn` |
| `VcssignSignConflicted` / `VcssignSignMissing` | `DiagnosticError` |
| `VcssignHeader`（分组标题） | `Comment` |

- `default = true` 定义，允许用户主题直接覆盖（gitsigns highlight.lua 同款策略）。

### 3.5 重渲染的触发与一致性

- 订阅 `Repo:on_update`（02 §3.1）→ 重渲染；`nvim_buf_is_valid` / 窗口仍开着才画。
- 保存光标行（`nvim_win_get_cursor`），重渲染后按「同 rel_path 优先，其次同 row」恢复光标（列表会增删行，不做会跳来跳去）。
- Repo 首轮刷新完成前显示 `── refreshing… ──` 单行占位。

## 4. 光标行 → 条目

```lua
renderer.item_at(buf, row) → vcssign.RenderItem?   # extmark 或行模型反查
```

- 行模型缓存在 `buf_states[bufnr] = { items = RenderItem[] }`（buffer-local 变量 `vim.b[bufnr].vcssign_items` 更简单，gitsigns 大量用 `vim.b[...]` 存 buffer 状态，采用后者）。
- keymap 与 actions（04）全部经此 API 取当前条目，**UI 层不接触任何 VCS 命令**。

## 5. keymap（keymap.lua）

窗口缓冲区局部（`nvim_buf_set_keymap`，`buffer = bufnr`），默认表（config 可覆盖，命名与 oil-vcs-status / gitsigns 风格一致）：

| 键 | 动作 | 备注 |
|----|------|------|
| `<cr>` | 打开文件（split，光标定位到该文件最近 diff 位置初版不做，就 `:e`） | 全 VCS |
| `t` | 新 tab 打开文件 | 全 VCS |
| `d` | 打开该文件 diff（04） | 全 VCS |
| `s` | stage（git） | capability 检查，svn 禁用并提示 |
| `u` | unstage（git） | 同上 |
| `r` | 手动刷新 | 全 VCS |
| `q` | 关闭侧边栏 | — |
| `?` | 弹出按键帮助（`vim.ui.select` 或 echo） | — |

- capability 不满足时：`vim.notify("svn: no staging area", vim.log.levels.INFO)`，**不映射失败动作的静默**。

## 6. 验收标准（实测）

| # | 标准 | 用例 | 实测 |
|---|------|------|------|
| 1 | git 三组 + 两位 sign（含 rename 的 `R` 与 orig_path 提示） | `sidebar_spec` 「the list groups by status and puts the state characters in two columns」/ `renderer_spec` 「a file in both domains…」 | ✅ 屏幕单元格实测 `│ A M`（both.txt）、`│ A  `、`│ M  `、`│ U  `；rename 文本 `new (from old)` |
| 2 | svn 单域、无 Staged 分组 | `sidebar_spec` 「an svn working copy renders one flat list…」 | ✅ 只 entry 行、单列 sign |
| 3 | 用户主题覆盖后跟随（`default=true`） | `renderer_spec` 「highlights are defined as defaults…」 | ✅ 用户 `fg` 存活，其余按文档链接 |
| 4 | 连续刷新不闪、光标跟文件走 | `sidebar_spec` 「the cursor stays on its file when rows appear above it」 | ✅ 上方插行后（行号变了）光标仍在同一 rel_path |
| 5 | dispose 后窗口关闭、缓冲区删除 | `sidebar_spec` 「a disposed repository takes its sidebar window and buffer with it」 | ✅ 窗口/缓冲区失效 + `fs_event` 回到 attach 前 |
| 6 | 1000 行重渲染 < 50ms（宽松 < 200ms） | `renderer_spec` 「a thousand rows render well inside the debounce window」 | ✅ build ≈1.7ms + draw ≈5.3ms ≈ **7ms**（1003 行，三次采样 6.5/7.5/6.8） |

额外（计划外但值得钉住）：窗口/缓冲区选项与 buffer name、toggle 三种语义与 buffer 复用、placeholder 三态（refreshing / 失败原因 / no changes）、按键真实按下（`feedkeys`）而非只测 `dispatch`、能力门先于动作层、keymap 覆盖与禁用。

## 7. 实测偏差、决定与遗留（实现后回写）

### 7.1 与计划草案的偏差

| # | 计划草案 | 实际实现 / 依据 |
|---|----------|-----------------|
| 1 | `nvim_open_win(0, true, { vertical = true, win = 9999 })` + `vertical resize` | `nvim_open_win(bufnr, enter, { split = "right"\|"left", width = N })`—0.12.4 实测支持 `split`，一句搞定且不动当前窗口的 buffer |
| 2 | upstream 位 `priority = priority + 100` | `+1000`（`renderer.upstream_offset`）。本地最高优先级是 `conflicted = 100`，`+100` 不能保证「index 位一定压过 local 位」，`+1000` 可以—这条不变量现在有测试钉住 |
| 3 | sign 位「双列」的列序未定义 | **实测**：priority 高的在**左**，窄列保留 priority 高的。于是 index 在左、worktree 在右—与 `git status --short` 的 XY 一致（`screenstring` 读真实屏幕得出，不是推断） |
| 4 | 分组标题 `── Staged ──` | `── Staged (2) ──`：带条目数，长列表里一眼看到规模 |
| 5 | svn「无分组或按状态种类分组」 | 取「无分组」：无 index 域时 `Staged/Unstaged` 是**假**信息；状态种类分组记入 backlog |
| 6 | 只有 `header` / `entry` 两种行 | 增加 `banner`：`refreshing…` / 错误原因 / `no changes` 三种占位—「还没加载」「加载失败」「真的干净」是三件事，界面必须说清是哪件 |
| 7 | 状态字符只在 sign 位 | sign 位仍是唯一的**字符**来源；额外用 `Vcssign<State>` 给**行文本**上色，让长列表可扫（`status_type.default_hl_group` 正是为此存在的） |
| 8 | `single_column` 初版可以只做双列 | 未实现（backlog）。侧边栏固定 `signcolumn=yes:2`，单列只在用户自行覆盖时出现，那时按实测规则保留 index 位 |
| 9 | `sidebar.position = "float"` schema 先占位 | schema 收下但未实现：`log.warn` + 回落 `"right"` |
| 10 | 窗口只在 `close` 时保留缓冲区 | 订阅（`on_update`/`on_error`/`on_delete`）**跟着缓冲区**走，不是跟着窗口—这样窗口隐藏时仓库消失也能把窗口和缓冲区一起销毁（否则会留下一个永远不更新的幽灵侧边栏） |
| 11 | 计划未提窗口 resize | 侧边栏自己挂 `VimResized`（augroup `vcssign_sidebar`）重画：截断宽度依赖窗口宽度，不重画就会一直显示旧截断。全局生命周期 autocmd 仍归 04 |

### 7.2 实现期踩到并修掉的坑

- **`vim.deepcopy` 一个 Repo 会抛**（`Cannot deepcopy object of type userdata`）：Repo 持有 `uv_fs_event_t` 句柄。`sidebar.forget_all()` 原想 deepcopy 映射表再遍历，改为**浅拷贝值列表**。探针先跑出来，否则会在「清场」路径上炸。
- **`item_at`/`entry_at` 的行号是 0 基**（与 extmark/`nvim_win_get_cursor` 减一后的约定一致），文档里写死，`cursor_entry` 统一做 `- 1`。第一版 spec 把它当 1 基写过，测试立刻报错。
- **`capture_notify` 必须 `vim.wait` 一小段再还原 `vim.notify`**：`log` 全部经 `vim.schedule` 投递，同步还原会让这些 warn 跑到真实 `vim.notify` 里、污染 stderr 并让断言漏掉它们。

### 7.3 backlog（明确不做，但记下来）

1. `sidebar.position = "float"`：浮动窗布局 + 跟随光标。
2. `sidebar.single_column`：合成列（index 优先），窄窗口下替代现在的「保留 index 位」规则。
3. `sidebar.group_by = "directory"`：目录树模式（oil-vcs-status `status_tree.lua` 是参考）。
4. 条目级增量更新（现在每次全量 clear + 重画；1000 行 7ms，暂不需要）。
5. 行文本截断策略可做成 config（当前固定「留尾」）。
6. 单 sign 位的行：sign 落在**左列**（priority 顺序决定），与 porcelain 的固定 X/Y 列位不同—要严格对齐得插一个占位 sign，收益不抵复杂度，先记下。
