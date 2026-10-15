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
  - `"right"`（默认）/ `"left"`：`nvim_open_win(0, true, { vertical = true, win = pos=="right" and 标号 9999 或 0 })`，打开后 `vim.cmd("vertical resize " .. config.sidebar.width)`（默认 `width = 40`）。
  - `"float"`：浮动窗（初版后置，schema 先占位）。
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

- 「git 单列窗口」场景：config `sidebar.single_column = true` → 合成显示策略（upstream 存在时取 upstream，`sign_text` 前缀区别），初版可以只做双列。

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

## 6. 验收标准

1. git 仓库：Staged/Unstaged/Untracked 三组渲染正确，两位 sign 状态正确（含 rename 的 `R` 与 orig_path 提示）。
2. svn 仓库：单列状态正确（upstream 位为空），无 Staged 分组。
3. 高亮组被用户主题覆盖后跟随变化（`default=true` 验证）。
4. 快速连续刷新（02 §5 用例 2）过程中：窗口不闪烁、光标行保持在同一文件上。
5. repo dispose 后窗口关闭、缓冲区删除，无残留 extmark（namespace 清理断言）。
6. 1000 条目仓库（fixture 大仓库用例）重渲染 < 50ms（`vim.loop.hrtime` 断言，宽松 CI 环境取 < 200ms）。
