# signcolumn / sign / extmark 语义（实测）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/sidebar/2026-10-16T17-33-54-sidebar-ui.md` §3.3、
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §2/§5.4、
> `loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`「M6 之后」。原文抽取，未做改写。

**要点**：同一列的多个 sign **priority 高的靠左，列宽不足时保留 priority 高的**（这是双命名空间 + `+1000` 偏移的依据）；
`'signcolumn'` 是**窗口选项**，`vim.wo[bufnr]` 写不进；写窗口选项**即使值相同也会触发 `OptionSet`**
（noice 崩溃的根因）；本插件现在的决定是**布尔 `signcolumn`，从不写窗口选项**（D47 之后的收敛）。

---

*来源：`loop/archive/sidebar/2026-10-16T17-33-54-sidebar-ui.md`，原文 `### 3.3 extmark 状态位`*（标题层级已下移一级）

#### 3.3 extmark 状态位

- namespace：`nvim_create_namespace("vcssign.sidebar")`；每次重渲染 `nvim_buf_clear_namespace` 后整体重画（条目级 diff 增量更新初版不做，数据量在几百条内全量重画开销可忽略；gitsigns manager 用全量 clear+重画也验证过该策略够用）。
- 每个条目行**两个 extmark**（oil-vcs-status `add_symbol_to_buffer` 同款）：

```lua
-- index 位（git 才有；svn 只有 worktree 位）
nvim_buf_set_extmark(buf, ns, row, 0, {
    sign_text = " " .. symbol,               -- sign_text 必须 1-2 字符，取 status_type 的 symbol
    sign_hl_group = "VcssignSign" .. Camel(type),   -- e.g. VcssignSignModified
    priority = priority + 1000,              -- 见下：index 位整体高于 worktree 位
})
-- worktree 位: priority = priority
```

> 术语按 D11：`index`（暂存区，git 的 X 列）/ `worktree`（工作区，Y 列），不再叫 upstream/local。

**sign 列的实际排布（`screenstring` 实测，0.12.4）**：同一列的多个 sign **priority 高的靠左**，列宽不足时**保留 priority 高的那个**。
因此 index 位的偏移取 `+1000`：worktree 域里最高的 `conflicted = 100`，只有 `+1000` 才能让「有 index 位就一定显示 index 位」这条不变量对**所有**组合成立（`+100` 会被 `conflicted` 顶掉，这个错误在 M3 实现时被实测抓出来，并有用例钉住）。
结果正好是 `git status --short` 的 XY 观感：index 在左、worktree 在右，窄列时留下的是已暂存状态。

> 单列窗口（`sidebar.single_column`）**未实现**，见 §7：`yes:2` 是侧边栏的固定形态，单列只在用户自己覆盖 `signcolumn` 时出现。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `## §2 关键决策（D38–D48）`*（标题层级已下移一级）

### §2 关键决策（D38–D48）

| 决策 | 内容 | 理由（为什么） |
|---|---|---|
| **D38** | 只做 sign，`Repo` 降级为「仓库会话」：去掉状态缓存与工作树遍历监听，只保留 `metadata_path`（git worktree/submodule 的 `gitdir:` 目标、svn 的 `.svn`）监听 + 防抖 + 退避重试 + 订阅广播 + `dispose` | sign 需要的是「基线文本变了」而不是「仓库里有什么」；`git status` 是 O(树)，每次编辑后跑一次是纯浪费 |
| **D39** | 比对引擎用 nvim 内置 diff（`vim.text.diff`，`a`=基线文本、`b`=缓冲区文本），不为每个缓冲区起 `git diff` 进程；`diff.use_external = false` 为默认，保留 opt-in 外部回退位（backlog） | svn 没有 `git diff` 这类本地后端，内部 diff 让 git/svn 走同一条路；省进程、省临时文件、易测（纯函数） |
| **D40** | hunk 类型与 gitsigns 对齐：`add\|change\|delete\|topdelete\|changedelete\|untracked`；git 暂存态用**双命名空间** + `filter_common` 拆「已暂存/未暂存」 | 同一行不会两层 sign 打架；类型名与用户熟悉的 gitsigns 一致 |
| **D41** | patch 走 stdin：`git apply --cached --unidiff-zero -`、`git apply -R --unidiff-zero -`；svn **不支持 stdin**（见 §5 C6）→ `vim.fn.tempname()` 落临时文件 `svn patch --strip 0 <file>` 并删除 | git 侧省临时文件；svn 侧被 CLI 限制逼成临时文件 |
| **D42** | 基线 = 配置 `rev`（默认 `index`）：git `index` ↔ svn `BASE`；未跟踪/未纳管 → 空基线 + `untracked` sign（`attach_to_untracked=true`）；索引里查不到的冲突文件回落 `HEAD` | 冲突文件在 index 里没有 stage 0（见 §5 B1），若不回落会整文件显示成「新增」 |
| **D43** | 行尾统一靠两处：`exec` 的 `text=true`（stdout CRLF→LF）+ diff 的 `ignore_cr_at_eol = true`；缓冲区文本用 `nvim_buf_get_lines` 拼 `\n`（不含 CR） | 本机是 Windows；CRLF 差异若不消掉会让每一行都变成 hunk |
| **D44** | 键位默认与 gitsigns 同形：`]c`/`[c`（可带计数、可环绕）+ `<leader>h{s,r,S,u,R,p,b,d,D,q,tw}`，buffer-local，`config.keymaps = false` 整体关 | 用户迁移成本低 |
| **D45** | reset 类动作保护未保存改动：`vim.bo.modified` 为真时**拒绝并提示**（「有未保存修改，先 `:w` 或 `:e!`」），不做内存内 patch 应用 | gitsigns 用 text edit 同步改缓冲区，我们初版不做（列为 backlog）；拒绝比静默丢改动安全 |
| **D46** | 不引入 async 框架（沿用回调链 + 错误优先 `cb(err, ...)`）、不动 D19「回调在主循环」契约、不新增依赖 | 与 M1–M5 的架构契约一致 |
| **D47** | `signs.culhl` 用 Neovim 原生的 extmark 选项 `cursorline_hl_group`（与 gitsigns 同款），不建 `CursorMoved` 刷新链路，也不把它写进 `place` 的早退条件 | 原生机制只作用于带 `'cursorline'` 的光标行上的 sign 格，而 `signcolumn = false` 时没有 sign 文本也就没有那个格，自建刷新链只会白跑；gitsigns 的 guard 同样不含 `culhl` |
| **D48** | `setup()` 结束前扫一次**窗口里的缓冲区**（`nvim_list_wins` 去重 → `attach.attach`），资格判断仍全部在 `attach.attach` 内 | 懒加载触发挂在 `BufEnter` 上时，插件是在该事件**之后**才配置的，当前文件不会再收到任何事件；只扫可见的窗口而不是全部已加载缓冲区（gitsigns 做的是后者：`"Attach to all open buffers"`），免得为会话里的历史缓冲区白挂仓库；隐藏缓冲区靠自己的 `BufEnter` 补上，不会漏 |

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §5.4 extmark sign 可见性（headless，→ §3.2 放置规则）`*（标题层级已下移一级）

#### §5.4 extmark sign 可见性（headless，→ §3.2 放置规则）

探针：真实文件 + `nvim_win_set_buf` + `vim.wo.signcolumn=…` + `nvim_buf_set_extmark(…, {sign_text=…, sign_hl_group='ErrorMsg'})`
+ `redraw` + `screenstring` 扫列。**headless 下 `screenstring` 可用**，能直接读屏幕单元格。

**`signcolumn` 变体（sign 在第 2 行，读 col1..5）**

| 值 | effective | row2 col1..5 | 可见 |
|---|---|---|---|
| `no` | `no` | `B B B B _` | **不可见** |
| `number` | `number` | `X _ B B B` | 可见（第 1 列） |
| `auto` | `auto` | `X _ B B B` | 可见（第 1 列） |
| `yes` | `yes` | `X _ B B B` | 可见（第 1 列） |
| `yes:2` | `yes:2` | `X _ _ _ B` | 占 4 格，文本第 5 列 |
| `auto:2` | `auto:2` | `X _ B B B` | 按实际 sign 宽度，只占 1 列 |

- **`signcolumn=yes:2` 时 sign 落在第 1 列（靠左，不靠右）**；单个 sign → `S _ _ _ B B`。
  开 `number` 时 → `S _ _ _ _ _ 2 _`（sign 列在数字列**左侧**）。
- **同一行两个命名空间（`yes:2`）**：`ns1 X(p0)` 后 `ns2 Y(p0)` → `Y _ X`；`ns1 X(p10)` 后 `ns2 Y(p20)` → `Y _ X`；
  `ns1 XX(p0)` 后 `ns2 Y(p0)` → `Y _ X X`。**规则：最左列=优先级最高者，同优先级则后加者胜；第二个 sign 落在第 3 列。**
- **`virt_lines` 与 sign 可共存**：默认渲染在该行**下方**（真实行有 sign，虚行 sign 列为空）；`virt_lines_above` 则在其上方。sign 只落在真实行。
- **`sign_text` 最多 2 个显示单元格**：接受 `'X'`、`'XX'`(2 格)、`'▎'`、`'▎▎'`、`'●'`、`'▎X'`、`'аб'`；
  **`'XXX'` 与 `'▎▎▎'` 报 `Invalid 'sign_text'`**（多字节每字宽 1 可用）。

---

*来源：`loop/archive/bootstrap/2026-10-16T20-52-42-implementation-todo-index.md`，原文 `### M6 之后：按用户要求做的三处 gitsigns 对齐`*（标题层级已下移一级）

#### M6 之后：按用户要求做的三处 gitsigns 对齐

> 都是 M6 交付之后用户实测/点名要的，不是 §6 表里的步骤；实现细节见 `07` §6.1 末尾三条与 §6.3。

- `d743bba` `fix(attach)` —— **noice 崩溃**（用户实测）：`WinEnter` → `reapply_signcolumn` 会在别人的
  `nvim_win_call`（`:Noice history`）里写 `'signcolumn'`，而**写入窗口已有的值也会触发 `OptionSet`**
  （探针实测：同一个值写三次 = 三次事件），那条处理器链一炸就记在 `attach.lua:302` 上。当时修法是
  「先读后比 + `pcall` + 失效窗口跳过」（250 → 253 用例）。
- `55255cb` `refactor(signs)` —— **`signcolumn` 交给 gitsigns 的语义**：`config.signcolumn` 改成**布尔**
  （默认 `true`，只决定要不要写 `sign_text`；为 `false` 且 `numhl`/`linehl` 也关着时连 extmark 都不放），
  **插件从不写窗口的 `'signcolumn'`** —— 上面那次修复的整条路径（`set_signcolumn` /
  `reapply_signcolumn` / `WinEnter` 订阅 / 告警）连同删掉，这类崩溃不再有机会发生
  （253 → 250 用例；`attach_spec` 25 → 23，`autocmds_spec` 去掉两条窗口用例）。
- `f66b074` `feat(blame)` —— **行内 blame 全面对齐 gitsigns**：`current_line_blame_opts` 全套
  （`virt_text` / `virt_text_pos`（含 `right_align`）/ `virt_text_priority` / `delay` 500 → 1000 /
  `ignore_whitespace` / `use_focus` / `extra_opts`）、`current_line_blame_formatter` +
  `_nc`、新模块 `lua/vcssign/blame_formatter.lua`（gitsigns 的占位符表 + `:<strftime>` + `%R` 相对时间 +
  函数式 formatter）、模块级事件 augroup + 单个 extmark（`id = 1`）+ `vim.b.vcssign_blame_line[_dict]`；
  适配器补齐 porcelain 字段与 `orig_lnum`、`-w`、`extra_opts`，svn 从 `<date>` 解析 `author_time`。
  顺手修掉一个竞态（取数回来时「还要不要这个装饰」要再判一次）（250 → 260 用例；
  `blame_formatter_spec` 7 例、`blame_spec` 8 → 11）。

**工程门（`f66b074` 实测）**：`make test` → **`260 tests, 0 failed`**、`make format-check` 零输出、
`make lint` → `0 warnings / 0 errors in 48 files`；stderr 只剩 `repo_spec` retry 那一行。
