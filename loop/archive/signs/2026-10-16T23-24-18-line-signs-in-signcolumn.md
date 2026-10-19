# 07 · M6 行级 sign（signcolumn）：设计与前置探针实测（M6）

> 归档自早期计划文档 `07-signs-in-signcolumn.md`（M0–M6 实施计划，原 `impl/` 目录）。由 2026-10-16 的 `loop/` 迁移整篇移入 `loop/archive/`，状态：**已实现、冻结**。
> 文中 `00`–`07` 的简写指的是本目录下的归档文档，对照表见 `loop/archive/README.md`；
> 被抽取到 `loop/knowledge/` 的小节在正文里只留指针。

> **为什么写这份文档**：M6 把插件从「文件级状态侧边栏」整体转向「行级 hunk sign」——
> 这是目标层面的转向，不是一个新功能。转向的理由（`git status` 是 O(树) 而 sign 只需要
> 基线文本）、随之冻结的接口与配置面（`VcsCaps`、适配器 `show/blame/apply_patch`、
> `signs/rev/diff` 段）、以及「必须先测后写」的若干反直觉约束（`:e!` 走 `on_detach`、
> `svn patch` 冲突仍退 0、`histogram` 慢 10 倍……），如果只留在临时探针报告里，
> Step 2 之后的每一步实现都要重新踩一遍。这里把它们固化下来，作为 03 / 04 的 M6 继任文档
> 与 Step 2–14 的唯一设计与实测依据。
>
> **来源**：`.pi/plans/2026-10-16T11-23-05-m6-signs-in-signcolumn.md`（计划）
> + `temp/m6_probe_results.md`（Step 0 探针实测，nvim 0.12.4 / git 2.55.0.windows.2 /
> svn 1.14.5 / Windows 11 + git-bash）。**本文只收录实测过的数字与原报错文本**，
> 未测到的写进 §11「待验证项」。

---

## §0 目标转向与范围

| 维度 | M0–M5（旧） | M6（新） |
|---|---|---|
| 呈现 | 独立侧边栏窗口 + 专属缓冲区，列文件的整体状态 | 当前缓冲区的 `'signcolumn'`，逐行标注 hunk |
| 数据源 | `git status` / `svn status`（O(树)） | 基线文本（git=index、svn=BASE）与缓冲区文本做**行级 diff** |
| 刷新触发 | 工作树词法监听 + `git status` | 缓冲区 `on_lines` 防抖 + 仓库元数据（`.git`/`.svn`）变化 |
| 粒度 | 文件级（open / stage / commit） | hunk 级（导航 / 暂存 / 丢弃 / 预览 / 行内高亮 / blame） |

**要交付的**：打开 git/svn 仓库里改过的文件 → signcolumn 逐行显示增/改/删/首行删/增删混合/未跟踪；
编辑即刷新；`]c`/`[c` 导航；hunk 级暂存/丢弃；行内 word-diff 与删除行预览；blame 与任意 rev 比对。
git 与 svn 同时交付（基线 git=index、svn=BASE），能力差异用 `VcsCaps` 门控而不是分叉两套代码。

---

## §1 差距总览（保留 / 删除 / 重写 / 新增）

| 模块 | 处置 | 说明 |
|---|---|---|
| `lua/vcssign/vcs/base.lua` | 保留 + 扩展 | 路径助手、`VcsCaps` 换字段、`unsupported()` 保留 |
| `lua/vcssign/vcs/init.lua` | 保留 | `detect`/`get_root_async`/`is_definitive_negative` 不动 |
| `lua/vcssign/vcs/git.lua` | 改造 | 删 `parse_status`/`status`；新增 `show/is_tracked/blame/apply_patch/revert`；保留 `stage/unstage/commit/diff` |
| `lua/vcssign/vcs/svn.lua` | 改造 | 删 `parse_line`/`parse_status`/`status`；新增同上五个接口；保留 `commit/diff` |
| `lua/vcssign/exec.lua` | 加一处 | `M.run` 的 spawn opts 加 `stdin = opts.stdin`（patch 走 stdin） |
| `lua/vcssign/repo.lua` | 收敛 | `_do_refresh` 不再调 `system.status`；删 `entries/get_entry/get_status/_apply_status` 与工作树监听集，只留 `metadata_path` 监听 |
| `lua/vcssign/repo_manager.lua` | 保留 | `attach/hold/ensure/detach/ref_count/dispose_all` 语义不变 |
| `lua/vcssign/sidebar/*` | 删除 | 连同 `test/sidebar_spec.lua`、`test/renderer_spec.lua` |
| `lua/vcssign/status_type.lua` | 删除 | 文件级状态枚举 → 由 `hunk.lua` 的 hunk 类型取代；高亮定义搬到 `signs.lua` |
| `lua/vcssign/actions.lua` | 重写 | 去 `open/open_tab` 与侧边栏取行；文件级动作 → hunk 级动作 |
| `lua/vcssign/cli.lua` | 重写 | 子命令换成 sign 语义 |
| `lua/vcssign/autocmds.lua` | 重写 | 按缓冲区 attach/detach、`BufWritePost`/`FocusGained` 刷新、`VimLeavePre` 清理 |
| `lua/vcssign/init.lua` | 重写 | 公共 API 改为 sign 语义（`attach/detach/toggle/refresh/get_hunks/diffthis/nav_hunk/stage_hunk/reset_hunk/blame_line`） |
| `lua/vcssign/config.lua` | 改配置面 | 删 `sidebar`；新增 `signs/signs_staged/signcolumn/max_file_length/attach_to_untracked/rev/keymaps/word_diff/deleted_preview/current_line_blame/update_debounce_ms` |
| 新增 `hunk/diff/attach/signs/nav/worddiff/preview/blame/revdiff/keymap.lua` | 新增 | 见 §3 |
| `plugin/vcssign.vim` | 微调 | 只注册 `:Vcssign`（保持懒 `require`） |
| `doc/vcssign.txt` + 早期计划文档 | 回写 | 本文即其中一份 |

**已在本仓库 runtime 核对的可用原语（无需外部依赖）**
- `vim.text.diff(a, b, opts)`（0.11+ 名字，`vim.diff` 为兼容别名）：`result_type='indices'` → 1 基
  `{start_a, count_a, start_b, count_b}`；`on_hunk = fn` 逐 hunk 回调（返回负数中断）；
  `algorithm ∈ myers|minimal|patience|histogram`；`ignore_cr_at_eol`；`linematch`（需 `indices`）。
  文档：`nvim/runtime/doc/lua.txt:4985-5058`。
- `vim.system` 支持 `stdin = string|string[]|true`（`lua.txt:4960-4963`），`text=true` 把 stdout/stderr 的 `\r\n` 归一为 `\n`。
- extmark 的 `sign_text/sign_hl_group/number_hl_group/line_hl_group/priority` 可作 sign 列（0.10+；本机 0.12.4）；
  sign 列必须开着才看得见；插件**不**代设窗口选项（M6 之后对齐 gitsigns，见 §6.1 末条）。
- 测试基建已够用：`helpers.{git_repo,svn_repo,svn_checkout,git_worktree,wait_for,uv_count,screen_line,capture_notify,with_repo,scratch_dir,entry,cleanup}` + `scripts/run_tests.sh` + `make test/lint/format-check`。

---

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/decisions.md`
>
> D38–D48 的全文与理由都在该文档里。

---

## §3 目标架构与适配器接口

```
plugin/vcssign.vim          :Vcssign 注册（懒 require）
lua/vcssign/init.lua        公共 API（薄壳，全部转发）
lua/vcssign/config.lua      配置面（signs/diff/word_diff/preview/blame/keymaps/rev）
lua/vcssign/attach.lua      每缓冲区附着状态：repo → 基线文本 → hunks → 渲染；on_lines/on_reload/on_detach
lua/vcssign/hunk.lua        hunk 模型：类型/区间/排序/比较/filter_common/patch 文本构造（纯函数）
lua/vcssign/diff.lua        纯函数引擎：texts → hunks（内置 diff 为默认）
lua/vcssign/signs.lua       extmark 双命名空间 sign + numhl/linehl/culhl + 高亮定义 + 清除
lua/vcssign/nav.lua         hunk 导航（有向、计数、环绕）→ 光标定位
lua/vcssign/worddiff.lua    行内高亮（change/changedelete 的成对行）
lua/vcssign/preview.lua     删除行 virt_lines 预览 / hunk 浮窗预览
lua/vcssign/blame.lua       当前行 blame（虚文本 + 浮窗），git/svn 两个后端
lua/vcssign/revdiff.lua     与任意 rev 比对（scratch 缓冲 + 窗口 diff）
lua/vcssign/keymap.lua      默认键位 → actions.dispatch（buffer-local）
lua/vcssign/actions.lua     hunk 级动作 + 文件级动作 + 能力门
lua/vcssign/cli.lua         :Vcssign 子命令 + 补全
lua/vcssign/autocmds.lua    生命周期触发器
lua/vcssign/repo.lua        仓库会话（监听元数据 + 防抖 + 重试 + 广播）
lua/vcssign/repo_manager.lua 引用计数（不动）
lua/vcssign/vcs/*.lua       适配器（根探测 + 基线文本 + 暂存/丢弃 + blame）
lua/vcssign/exec,log,util,debounce.lua  既有基建（exec 加 stdin）
```

### §3.1 适配器接口（M6 版）

```lua
---@class vcssign.VcsCaps
---@field stage boolean          能写 index（git）
---@field staged_signs boolean   有 HEAD↔index↔worktree 三层（git）
---@field revert_hunk boolean    hunk 级丢弃
---@field blame boolean
---@field show_rev boolean       `show(rev, file)`
---@field commit boolean

---@field show fun(root: string, rev: string|'BASE', rel: string, cb: fun(err: string?, text: string?))
---     git: `git show <rev>:<rel>`（rev=='index' 时用 `:<rel>`）
---     **实测更正（原写「HEAD 不存在（unborn）→ 等价于空基线」）**：`git show HEAD:<rel>` 在
---     unborn 仓库返回 code 128 `fatal: invalid object name 'HEAD'.`，并不等于空基线；
---     只有 `git show :<rel>` 可用（空仓库下 code 0，直接读暂存内容）。调用方要空基线
---     必须自己先 `is_tracked` 判定再决定，不能依赖 HEAD 回落。
---     svn: `svn cat -r <rev|BASE> <file>`
---@field is_tracked fun(root: string, rel: string, cb: fun(err: string?, tracked: boolean?))
---     git: `git ls-files --error-unmatch -- <rel>`；svn: `svn info -- <abs>` 的退出码（非零 ⇒ 未纳管；见 §5.3 的实测更正）
---@field blame fun(root: string, rel: string, opts: {from: integer, to: integer}, cb)
---     git: `git blame --line-porcelain -L a,b -- <rel>`；svn: `svn blame --xml`（整文件缓存）
---@field apply_patch fun(root: string, patch: string, opts: {cached?: boolean, reverse?: boolean}, cb)
---     git: `git apply [--cached] [-R] --unidiff-zero -`；svn: 临时文件 + `svn patch --strip 0`
---@field revert fun(root: string, rel: string, cb)   -- 整文件丢弃（svn revert / git checkout -- <rel>）
```

`exec.M.run` 的 `---@class vcssign.ExecOpts` 增加 `stdin?: string|string[]`，并在 spawn opts 里透传
（`opts.stdin` 与超时/`finish` 的交互、写 stdin 失败是否终止子进程，Step 2 里写清楚）。

### §3.2 hunk 模型与 sign 放置规则（`signs.lua`，逐条写测试）

- `add`：`added` 每行一个 sign。
- `change`：`added` 每行一个 sign；若 `removed.count > 0`，`added` 末行改用 `changedelete`。
- `delete`（`added.count == 0`）：`removed.start > 1` → 在 `removed.start - 1` 行放 `▁`；
  `removed.start == 1` → 第 1 行放 `topdelete`（`‾`）。
- `untracked`：文件未跟踪时整缓冲区一个 `┆`。
- `numhl/linehl` 开关分别写 `number_hl_group`/`line_hl_group`；`culhl` 写 `cursorline_hl_group`（Neovim
  原生 extmark 选项：只在带 `'cursorline'` 的光标行的 sign 格上生效，无需 `CursorMoved` 刷新，
  见 D47）。
- `culhl` 不参与 `place` 的早退判断：`signcolumn = false`（无 sign 文本）时没有 sign 格可上色。

---

## §4 配置面与高亮组

```lua
signs = {
  add = { text = '▎' }, change = { text = '▎' }, delete = { text = '▁' },
  topdelete = { text = '‾' }, changedelete = { text = '~' }, untracked = { text = '┆' },
  numhl = false, linehl = false, culhl = false,
  max_file_length = 40000,
},
signs_staged = { add = {...}, change = {...}, delete = {...}, ... },  -- git：已暂存那一层
signcolumn = true,              -- gitsigns 语义：是否画 sign 文本；插件从不改窗口的 'signcolumn'
rev = 'index',                  -- 'index' | 'HEAD' | 任意 rev/rev 表达式
attach_to_untracked = true,
update_debounce_ms = 200,       -- 注意：M2 旧默认 300（为 `git add` 事件风暴选的），需改并同步 doc/config_spec
watch_gitdir = true,
diff = { use_external = false, algorithm = 'myers', indent_heuristic = true, linematch = true, ignore_cr_at_eol = true },
word_diff = false,
deleted_preview = false,        -- 删除行以 virt_lines 内联预览
current_line_blame = false,
current_line_blame_opts = { delay = 500, virt_text_pos = 'eol' },
keymaps = { ['[c'] = 'prev_hunk', [']c'] = 'next_hunk', ['<leader>hs'] = 'stage_hunk', ... },  -- false 整体关闭
commit = { message_input = 'input' },
```

**高亮组**（`signs.define_highlights()`，`default = true`，允许用户主题覆盖）：
`Vcssign{Add,Change,Delete,TopDelete,ChangeDelete,Untracked}` 及其 `…Staged`、`…Ln`、`…Nr`、`…Cul` 变体，
默认先取主题为 git sign 准备的组（`GitGutter*` / `SignifySign*` / `Diff{Added,Removed,Modified}Gutter`，即 gitsigns 候选链去掉 `GitSigns*`），都没有才 link 到 `DiffAdd/DiffChange/DiffDelete`（Staged 用更暗的链接，参考 gitsigns 的 `GitSignsAddStaged`）。
命名空间：`vcssign_signs`、`vcssign_signs_staged`、`vcssign_worddiff`、`vcssign_preview`、`vcssign_blame`。

---

## §5 探针实测（Step 0，浓缩表）

> 环境：Windows + git-bash；**nvim 0.12.4**（`--headless -u NONE -l`）；**git 2.55.0.windows.2**；**svn 1.14.5**。
> 探针脚本 `temp/probe_m6_*.lua`，自建仓库在 `temp/_probe/`（均不进版本库）。
> **以下每条都带实现结论**，Step 2+ 直接照做，不需要回读临时报告。

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/nvim/libuv-and-vim-system.md`
> - `loop/knowledge/nvim/diff-and-hunks.md`
> - `loop/knowledge/vcs/svn-output-formats.md`
> - `loop/knowledge/nvim/signs-and-extmarks.md`
>
> §5.1/§5.5 在 libuv 文档，§5.2 在 diff 文档，§5.3 在 svn 文档，§5.4 在 signs 文档；§5.6（性能）保留在下方。

---

### §5.6 性能（→ D39 / D44 默认值）

**`vim.text.diff`（每 200 行改 1 行 + 每 500 行插 1 行，`result_type='indices'`，3 次取最优）**

| N（行） | 耗时 | hunks |
|---|---|---|
| 1000 | **0.12 ms** | 6 |
| 5000 | **0.66 ms** | 30 |
| 20000 | **2.77 ms** | 120 |
| 40000 | **5.55 ms** | 240 |

算法（N=20000）：**`myers 2.29ms`（默认，最快）**、`minimal 2.42ms`、`patience 3.76ms`、
**`histogram 22.04ms`（约 10 倍慢）**。极限：全不同 20000 行 `2.33ms`；全重复 20000 行 `7.45ms`。

**结论**：20000 行 ~3ms 完全可接受；**`max_file_length = 40000` 合理（~5.5ms）**；**用默认 `myers`，别用 `histogram`**。

**`nvim_buf_set_extmark` 1000 个 sign：0.55 ms（~0.001 ms/sign）**；1000 个 inline-hl 0.60ms；`clear_namespace` ~0.000ms。
**批量放 sign 不是瓶颈**。

---

## §6 分步实施与落地状态

> 每步的门槛：`sh scripts/run_tests.sh` 全绿 + `make format-check lint` 干净 + 一个可 bisect 的提交。
> **耦合警告（贯穿全程）**：`test/doc_spec.lua` 断言「`config.defaults` 的每个 key、`cli.subcommands`、默认键位动作、
> hunk/高亮名、公共 API 名」都在 `doc/vcssign.txt` 里出现。**任何一步只要动了配置面/CLI/API/键位，必须同一步更新
> `doc/vcssign.txt` + `test/doc_spec.lua`**，否则该步红。

| Step | 内容 | 状态 |
|---|---|---|
| **1** | **减法：退役侧边栏，留最小 sign 骨架**——删 `lua/vcssign/sidebar/`、`status_type.lua`、3 个 spec；`config` 删 `sidebar` 增 sign 段；`cli.subcommands` 收敛；`init` 删 sidebar API；`doc/vcssign.txt` 改写保持 `doc_spec` 绿。提交 `refactor!: 退役侧边栏，改为行级 sign 骨架（M6 起点）` | ✅ **已完成**（`080379c`，测试 **174 → 125**，全绿） |
| 2 | `Repo` 收敛（只监听 `metadata_path` + 广播）+ `exec` 支持 `stdin`；`repo_spec` 21→约 12、`exec_spec` 9→11 | ✅ **已完成**（`3ecbdd7`，128 用例；本步引入的回归见 §6.1，`f1d1735` 修） |
| 3 | `hunk.lua`（类型/`from_indices`/`sort`/`dedupe`/`filter_common`/`build_patch`/`lines_of`）+ `diff.lua`（`vim.text.diff` 封装）；`hunk_spec` 约 12、`diff_spec` 约 8 | ✅ **已完成**（`5e8e485`，125 → 158 用例） |
| 4 | 适配器新接口 `show/is_tracked/blame/apply_patch/revert`；`VcsCaps` 换字段；`vcs_git_spec`/`vcs_svn_spec` 各约 10–12 | ✅ **已完成**（`7acc713`，150 用例；两处探针结论在 `e6c4f1b` 更正） |
| 5 | `signs.lua`（双命名空间 + 放置规则 + numhl/linehl）+ `attach.lua`（守卫/基线/diff/渲染/`nvim_buf_attach`）；`attach_spec` 约 14 | ✅ **已完成**（`6eaef2b`，150 → 178 用例） |
| 6 | 刷新触发（`on_lines` 防抖 / `on_reload` / `repo:on_update`）+ 生命周期 autocmd + 开关；`autocmds_spec` 10→12、`cli_spec` 11→13、`attach_spec` 14→16 | ✅ **已完成**（`2193802`，178 → **184** 用例，全绿） |
| 7 | git 暂存态双层 sign（`filter_common(HEAD↔buf, unstaged)` + `signs_staged` 高亮） | ✅ **已完成**（`4bfe0ce`，184 → **189** 用例，全绿） |
| 8 | `nav.lua`（`]c`/`[c`，计数/环绕）+ `keymap.lua`；`nav_spec` 13 | ✅ **已完成**（`f54b6af`，189 → **202** 用例，全绿） |
| 9 | hunk 级动作（`stage_hunk`/`unstage_hunk`/`reset_hunk`/`stage_buffer`/`reset_buffer`）+ CLI；`actions_spec` 19→30 | ✅ **已完成**（`a5e544a`，202 → **213** 用例，全绿；`preview_hunk` 挪到 Step 10，见 §6.1） |
| 10 | `worddiff.lua`（成对行按段 diff）+ `preview.lua`（`virt_lines` 删除预览 / hunk 浮窗） | ✅ **已完成**（`1317890`，213 → **229** 用例，全绿；`worddiff_spec` 9 + `preview_spec` 7） |
| 11 | `blame.lua`（`current_line_blame` + `blame_line` 浮窗）+ `revdiff.lua`（`diffthis [rev]`）；各约 6 | ✅ **已完成**（`22ad24a`，229 → **244** 用例，全绿；`blame_spec` 8 + `revdiff_spec` 7） |
| 12 | 文档与帮助回写（`00`–`06`、`doc/vcssign.txt`、`doc_spec`） | ✅ **已完成**（`a4b3551`，用例数仍 **244**，全绿；`doc_spec` 6/6 单跑） |
| 13 | 独立审查（`code-reviewer` 审 M6 起点..HEAD）+ 修复 | ✅ **已完成**（审查 runId `del_mvas87sc_mefj`，完整报告 `temp/m6_review.md`；修复 `c2990be`，244 → **250** 用例，全绿） |
| 14 | 终验（全量两遍幂等、stderr 合同、`git diff --check` 干净、逐 SHA 复跑） | ✅ **已完成**（`a3e41fd`；M6 收尾，**250/250** 两遍全绿、stderr 只剩 retry 那一行、逐 SHA 复跑见 §6.1） |

> **减法步骤（Step 1）的判据是「删干净 + 全绿 + 文档/`doc_spec` 同步」**，不追求功能完整；
> 功能在 Step 3+ 逐步补回。`Repo` 本体到 Step 2 才动，Step 1 只删调用者，以保 `repo_spec` 可跑。

---

### §6.1 已落地（截至 `a3e41fd`）

| SHA | 提交 | 验证（`make test`） |
|---|---|---|
| `080379c` | M6 起点：退役侧边栏，留最小 sign 骨架 | 174 → **125**，全绿 |
| `9b4eb90` | 07 设计与探针实测（纯文档） | — |
| `3ecbdd7` | Step 2：`Repo` 降级为元数据会话 + `exec` 支持 `stdin` | **128**，其中 2 个 repo_spec 用例红（见下） |
| `5e8e485` | Step 3：`hunk.lua` + `diff.lua` | 125 → **158** |
| `7acc713` | Step 4：适配器换血（`show` / `is_tracked` / `blame` / `apply_patch` / `revert`） | **150**（重写 vcs_git/vcs_svn 用例，158 → 150） |
| `f1d1735` | `fix(repo)`：根目录加非递归 watch（修 Step 2 的回归） | **150**；`FILTER=repo_spec` 连跑两次均 20/20 |
| `e6c4f1b` | `fix(vcs)`：svn 追踪判定改用 `svn info` + 07 两处实测更正 | **151** |
| `6eaef2b` | Step 5：`signs.lua` + `attach.lua` | 150 → **178** |
| `e4142b0` | 本文档：Step 1–5 标完成 + §6.1–§6.4 交接说明（纯文档） | — |
| `2193802` | Step 6：自动触发、生命周期与逐缓冲开关（`autocmds` / `cli` / `init` 接到 `attach`） | 178 → **184**，全绿；本步动到的三个 spec 单跑 **41/41** |
| `4bfe0ce` | Step 7：git 暂存态双层 sign（`load_head` + `filter_common` + `…Staged` 暗色） | 184 → **189**，全绿；`attach_spec` 16、`signs_spec` 14 单跑 **34/34** |
| `f54b6af` | Step 8：hunk 导航与默认键位（`nav.lua` + `keymap.lua` + `signs.sign_line`） | 189 → **202**，全绿；`nav_spec` 13/13，本步动到的五个 spec 单跑 **72/72** |
| `a5e544a` | Step 9：hunk 级动作（`actions.lua` 的五个动作 + `attach.ready` 等待者 + CLI / keymap 接线） | 202 → **213**，全绿；`actions_spec` 19 → 30，本步动到的四个 spec 单跑 **76/76** |
| `5942dd9` | `fix(test)`：`repo_spec` 的探针计数限定到被测仓库（Step 10 全量首跑的 flake） | 用例数不变，只让全量运行稳定 |
| `1317890` | Step 10：词级 diff 与 hunk 预览（`worddiff.lua` + `preview.lua` + 渲染出口 `clear_layers` + CLI / keymap 接线） | 213 → **229**，全绿；`worddiff_spec` 9 + `preview_spec` 7 单跑 **16/16** |
| `22ad24a` | Step 11：当前行 blame 与 `diffthis [rev]`（`blame.lua` + `revdiff.lua` + `preview.M.open`） | 229 → **244**，全绿；`blame_spec` 8 + `revdiff_spec` 7 单跑 **15/15** |
| `a4b3551` | Step 12：文档与帮助回写（`00`–`05` 加 M6 标记、05 补实况表、07 §5.3 / §11 更正、`doc/vcssign.txt` 三处措辞） | 用例数仍 **244**，全绿；`doc_spec` 6/6 |

**工程门（`a4b3551` 实测）**：`make test` **244/244**（同一棵树上空闲连跑两次都是 `244 tests, 0 failed`）、
`make format-check` 零输出、`make lint` → `0 warnings / 0 errors in 46 files`。

**Step 12 回读全文时更正的两处过时说法**（漂移的来源：旧文档把「当时的实现」写成了「设计要求」）：
① 07 §5.3 / §11 第 2 条曾写「`svn patch --strip 0` 不吃 git 风格头」——被 Step 9 的实测推翻（见 §6.3）；
② 04 的 `autocmds._attached`（「每个缓冲区只 attach 一次」的记忆表）已在 Step 6（`2193802`）删除，
「只 attach 一次」现在由 `attach.lua` 按路径去重实现。**以后做这类回写要逐段核对代码，不能只加新章节。**

**Step 2 引入的回归（交接要点，别再踩）**：Step 2 把监听集收敛成「只监听 metadata 目录」（D38），
而 **libuv 从不报告「被监听目录自身消失」** —— 实测：把 `.git` 改名走，挂在 `.git` 上的 handler
**一个事件都收不到**（0 events），挂在根目录上的非递归 handler 立刻收到 `.git` / `.git-gone` 的
rename 事件（3 events）。于是工作副本被删后 `Repo` 不会自杀，只能等某次无关的 refresh 失败才被回收；
`repo_spec` 的「`.git` 消失」「`.svn` 消失」两个用例因此在 `3ecbdd7` / `5e8e485` / `7acc713` 上
**过滤运行必红（`FILTER=repo_spec make test` → 2/20 失败）、全量运行间歇红**。

`f1d1735` 的修法：`_init_watch` 在 metadata 之外，对 **root** 再挂一个**非递归** watch，只作存活探测
（`_on_fs_event` 里已有的「marker 不存在 ⇒ `_mark_deleted()`」分支接管）。代价是根目录下的变更也会
触发刷新（非递归 + 去抖；`--no-optional-locks` 保证不自激）—— 这正是 M2 原本的监听集。

> **这三行「全绿」是在 flake 窗口里测到的**：`3ecbdd7` / `5e8e485` / `7acc713` 逐 SHA 复跑时，
> `FILTER=repo_spec make test` 会红。Step 14 的逐 SHA 复跑要按 §6.2 的流程重做一遍并如实记录。

**工程门（`6eaef2b` 实测）**：`make test` **178/178**、`make format-check` 零输出、
`make lint` → `0 warnings / 0 errors in 35 files`；工作区干净（只有 `.pi/` 计划目录未跟踪）。

**工程门（`2193802` 实测）**：`make test` **184/184**、本步动到的三个 spec 单跑 **41/41**、
`make format-check` 零输出、`make lint` → `0 warnings / 0 errors in 35 files`。

**Step 6 的三个红都是「等待条件不够」，实现没问题**（用例注释已写明，别再踩）：
1. `:Vcssign refresh` 会起**两条异步链**：仓库检测（绑 `cmd:` 引用）与缓冲区自己那次
   `attach`（绑 `attach:<bufnr>` 引用）。断言 `ref_count` 之前必须等
   `attach.state(bufnr).attached`，否则在**全量**运行里（前面的 spec 会留下在飞的检测）
   会读到只到位一半的引用数 —— 而单跑同一个 spec 反而过得去，是典型的顺序敏感 flake。
2. `toggle` 重新打开是**异步**的：它重读基线再渲染，`sign_count` 不会在下一次 `cli.run`
   返回时就有值；断言要 `wait_for`。
3. `VimLeavePre` 用例原本只等 `repo.has_loaded and not repo.is_updating`（覆盖 `Repo` 自己
   的探测）。Step 6 之后 `attach` 的 `load_base` 也会起 `exec`，而在飞命令的超时 timer 不
   受 `VimLeavePre` 影响（用例注释本来就承认这一半），所以等待条件要再补一条「缓冲区已渲染」。

**stderr 合同要留意**：进程 stderr 的行数会在 **0/1 之间浮动**。那一行来自 `repo_spec` 的 retry 用例
（`with_config({ exec_timeout_ms = 1 })`）里 `log.warn` 打出的超时告警，是否出现取决于命令有没有在
1ms 内跑完；用例本身不断言它。Step 14 要么把断言写成「0 或 1 行」，要么把该用例的 `vim.notify` 捕获掉。

**Step 8 的两个坑（都不是实现错，是写法错）**：

1. **Lua 的 `and/or` 空值穿透**：`forward and index_after(...) or index_before(...)` 在 `index_after`
   返回 `nil` 时会**静默走 `index_before` 分支** —— 探针里 `]c` 从最后一个 hunk 之后回绕应落到第 1 个
   hunk，实际跳到了最后一个。同一写法在 `window_for` 里也有：`bufwinid() == -1 and nil or win` 会返回
   `-1`（`-1` 是 truthy，`nvim_win_*` 收到会是错的窗口）。两处都改成显式 `if`。
2. **循环 require**：`attach` →（本步新增）`keymap` → `nav` → `attach`。keymap 里改成惰性 require
   （在函数内 `require('vcssign.nav')`）即可，不要在模块顶部形成环。

**新文件不在 `make format-check` 的清单里**：`Makefile` 的 `LUA_FILES` 是 `git ls-files` 的输出，
未 `git add` 的新文件既不被 `make format` 格式化、也不被 `make format-check` 检查（`make lint` 查目录，
所以能查到）。本步是先显式跑 `deps/stylua.exe <三个新文件>` 再 `git add`，之后 `make format-check`
才覆盖到 38 个文件（`lint` 同样 38 个）。

**工程门（`a5e544a` 实测）**：`make test` **213/213**、本步动到的四个 spec 单跑 **76/76**
（`attach_spec` 20 + `actions_spec` 30 + `nav_spec` 13 + `cli_spec` 13）、
`make format-check` 零输出、`make lint` → `0 warnings / 0 errors in 38 files`。

**工程门（`1317890` 实测）**：`make test` **229/229**、本步的两个新 spec 单跑 **16/16**、
`make format-check` 零输出、`make lint` → `0 warnings / 0 errors in 42 files`。

**Step 9 的三个决定（都写在代码注释里，交接时别改回去）**：

1. **`attach.ready(bufnr, cb)` 用等待者列表，不是轮询**：hunk 动作要求「先有基线再算 hunk」，
   而 `:Vcssign stage_hunk` 可能是会话里敲的第一条命令，那时基线还在路上。`attach` 是幂等的，
   `ready` 于是顺手把管线启动起来，再把 `cb` 排进 `st.waiters`；管线每个出口（无仓库 / 引用失守 /
   路径在仓库外 / 首次渲染 / 仓库消失 / `detach` / `forget_all`）都 `settle` 一次。
   **以后新增出口必须也 `settle`**，否则调用方会永远等下去。
2. **动作成功后除了 `repo:refresh_now()` 还要 `attach.refresh(bufnr)`**：仓库探测是去抖的
   （`update_debounce_ms`），而下一个 hunk 动作读的是缓冲区自己的图层。少了这一句，`hs` 紧跟
   `hu` 会答「no change on line N」—— spec 第一次就是这么红的。断言也要等插件的图层
   （`hunks_staged`），而不是等 `git diff --cached`：index 变了不等于图层追上了。
3. **未跟踪文件不走补丁**：它没有 index blob，`git apply --cached` 会拒绝。`stage_hunk` 直接落
   `M.stage`（整份文件），`reset_hunk` 回答「nothing to discard」。

**`preview_hunk` 挪到了 Step 10**：它要的是渲染（浮窗），Step 9 只做「改状态」的动作；§4 的
`hp` 键位当时仍然是占位提示，`1317890` 已经把它接上（见下面的第 3 条）。

**Step 10 的三个决定（交接时别改回去）**：

1. **词级 diff 按「段序列」做，不按字符序列做**：`vim.text.diff` / `vim.diff` 只收**字符串**（传列表会
   `bad argument #1 to '?' (expected string)`），而且只按 `\n` 分行。于是把一行切成「词 / 空白 / 标点
   （单个 UTF-8 字符）」的段，用 `\n` 连起来喂给它，拿到的 `indices` 就是「按段的 diff」；再把改动段
   映射回字节列（`end_col` 是**独占**语义）。中文因此是逐字粒度，正好是想要的。
2. **xdiff 的 hunk 两端可能带公共前后缀，必须自己剪**：`'a = 1 2' → 'a = 1'` 实测报成
   `{ start_a = 5, count_a = 3, start_b = 5, count_b = 1 }`（「删掉行尾的 ` 2`」被写成「`1`,` `,`2`
   换成 `1`」），直接渲染会在新行上多画一块「` 1` 是新增的」。`worddiff.M.ranges` 于是对每个 hunk 的
   a / b 段序列剪掉公共前缀与公共后缀，剪空了就不标。
3. **渲染出口只有一个，而且是三层一起清**：`attach` 新增的局部 `clear_layers(bufnr)`（sign + 词级 +
   预览）取代了原来的 `signs.clear`：`base_text == nil`、`shown == false`、`deactivate`、`detach`、
   `forget_all`、`toggle` 关掉 —— 六个出口都走它。以后再加一层渲染，先想清楚它在哪些出口要被清掉。
   另外 `word_diff` / `deleted_preview` 都是**渲染时现读** `config.get()`（改配置立刻生效，
   `toggle_word_diff` 只需要翻转配置 + `attach.refresh_all()`）；hunk 浮窗用 `filetype=diff` 借配色方案
   的高亮（不新开高亮组），`CursorMoved`（`once = true`、buffer-local）一关。

**Step 11 的三个决定（交接时别改回去）**：

1. **blame 的缓存键是 `changedtick`，不是时间**：`blame.lua` 给每个缓冲区存一份 `{tick, result}`，渲染
   时先比 tick —— 相等就直接复用，不等才重新 `blame`。所以「只移动光标」是零子进程的
   （`blame_spec` 用 `exec.run` 计数器断言 0 次），按一次撤销/重做才会重新问。装饰是 extmark 的
   `virt_text`（`eol`，前后各一个空格），落在 `vcssign_blame` 命名空间；关掉开关时 `blame.render`
   只清命名空间、不撤自动命令（重开零成本）。
2. **浮窗只有一个实现**：Step 10 的 `preview.toggle_hunk` 与新加的
   `preview.open(bufnr, lnum, text, opts)`（`opts.filetype` / `opts.title`）共用同一扇窗；`blame_line`
   走 `open`，所以 hunk 预览与 blame 的行为（同一个位置再按一次就关、`CursorMoved` / `BufLeave`
   自动关）是一份代码。
3. **diff 窗口从 `actions` 挪进了 `revdiff`**：`actions` 现在只剩 `M.diffthis` / `M.diffthis_rev`
   两个薄包装，`diffthis` 不带 rev 时**直接调 `M.diff`**（复用基线 diff 的全部行为，包括
   「no changes to show」），带 rev 时才走 `show(root, rev, rel)`。`revdiff.text` 写一次
   `diff --git` 三行头，每个 hunk 用 `hunk.build_patch(..., { headers = false })`，所以整段文本
   可以直接喂给 `filetype=diff` 的缓冲区。

**Step 10 全量首跑的那 1 个红不是本步的缺陷**：`repo_spec: a manual refresh inside the debounce
window is not run twice` 只在全量里红（`repo_spec` 单跑 20/20）。原因是 `repo_spec` 的
`count_probes` 数的是**所有**仓库的 `rev-parse` / `wc-root`，而这条用例的观察窗口有 2.3s ——
前面某个 spec 留下的仓库在窗口内应了自己的 watcher，计数就多一个。`5942dd9` 把计数限定到
**第一个**探测所在的 cwd（`fn` 一上来就动被测仓库），用例语义没变。再跑全量即 **229/229**。

**Step 13（独立审查，`%s`）**：`code-reviewer` 只读审了 `080379c^..HEAD`（24 提交 / 58 文件 /
+8956−4499），结论「**没有 blocker**」，但抓到一个真缺陷和一个假绿灯，两个都就地修掉：

1. **F1 attach 的死状态**（修）：仓库消失走 `deactivate` 时状态被标成 `attached = false` 却留在
   `M._bufs` 里，而 `M.attach` 的幂等分支（`prev.path == path` → 直接返回）把它当成「已经挂好了」——
   于是仓库重建后这个缓冲区**永远没有 sign**（`BufEnter` / `:Vcssign refresh` / 键位全撞在死状态上），
   唯一自救是 `:e!`。修法是把「仓库消失」与「这个文件本来就不在仓库里」分开：`deactivate` 打
   `abandoned` 标记，`M.attach` 只对 `abandoned` 的状态重建；「没有仓库」的答案仍然缓存（否则仓库外
   的文件每次 `BufEnter` 都重跑一遍检测），改由**显式**请求重试 —— `M.refresh` / `M.toggle` 走新增的
   `revive()`。三条用例：仓库消失后重建、仓库后建（`git init`）后 `refresh` 接上、`toggle` 在无状态
   缓冲区上返回「已开」而不是把刚建好的状态翻成关。
2. **F2 `hq` / `hQ` 的假绿灯**（修）：`setqflist` / `setqflist_all` 是默认键位、帮助里也写着「把 hunk
   放进 quickfix」，但 `keymap.ACTIONS` 里没有它们，按下去只会「not implemented yet」——`doc_spec`
   只查名字出现，所以全绿。现在 `keymap.PLACEHOLDERS` 显式列出这两个，帮助表各自标注「（未实现）」，
   并给 `doc_spec` 加了一条**语义**断言：默认键位的每个动作要么在 `M.ACTIONS` 里，要么在
   `PLACEHOLDERS` 里，且 `PLACEHOLDERS` 里不能有已实现的动作。
3. 其余就地修的小项：`set_signcolumn` 在 `signcolumn = false` 且全局是 `no` / `number` 时给一次性告警
   （07 §8 的承诺，此前从未实现），并新增 `M.reapply_signcolumn` + `autocmds` 的 `WinEnter` 订阅
   （`attach` 跑在 `BufReadPost`，那时缓冲区可能还没有窗口，`:split` 出来的新窗口会留在全局值上）；
   `keymap.detach` 只删自己装过的键（值不是字符串的 lhs 是用户自己的）；`vcs/svn.lua` 的
   `apply_patch` 注释改回实测结论（旧注释还在说「git 风格头会被拒」）。
4. 审查标为「待验证」的 **V1（`on_detach` 是否在 fast context）实测为否**：探针里 `on_lines` 与
   `on_detach` 都是 `vim.in_fast_event() == false`，所以 `M.detach` 直接在 `on_detach` 里调是安全的。
5. 进 backlog 而**不改代码**的两条：`patch_of` 用的是 `st.base_text`（磁盘被别的程序改过时补丁会对不上，
   表现是 git 报 `patch does not apply` —— 安全但不友好）；11 份 spec 各自复制 `guarded`。

**M6 之后的修复（用户实测）**：上面那条 3 里新增的 `WinEnter` → `reapply_signcolumn` 会在别人的
`nvim_win_call`（noice 开 `:Noice history`）里写 `'signcolumn'`，而「写入窗口已有的值」**同样触发
`OptionSet`**，于是 noice 视图的处理器一炸就记在 `attach.lua:302` 上。修复：先比后写（值相同就
不写）、失效窗口跳过、写用 `pcall`；`attach_spec` 三条新用例（值未变 0 次 OptionSet、值变了正好
1 次、失效窗口 id 不抛错）。细节见 §6.3 末条。

**M6 之后的对齐（用户要求）：`signcolumn` 交给 gitsigns 的语义**。上面那条 3 里的 `set_signcolumn` /
`reapply_signcolumn` / `WinEnter` 订阅与那次告警**全部删掉**了。现在 `config.signcolumn` 是**布尔**
（默认 `true`），与 gitsigns 的 `signcolumn` 一致，只决定 `signs.place` 是否写 `sign_text`；为 `false`
时如果 `signs.numhl` / `signs.linehl` 也都关着，`place` 连 extmark 都不放（gitsigns `signs.lua` 同款
短路）。插件**从不写窗口的 `'signcolumn'`** —— 它是窗口选项，由用户自己设（Neovim 默认 `'auto'` 有
sign 就开列）。这样 noice 那类崩溃不是靠「先比后写」绕开，而是整条写窗口选项的路径都不存在了。

**M6 之后的第二个对齐（用户要求）：行内 blame 全面对齐 gitsigns**。Step 11 的 `lua/vcssign/blame.lua`
按 gitsigns 重写了：

- `current_line_blame_opts` 现在与 gitsigns 同一套：`virt_text`、`virt_text_pos`（也支持
  `right_align`，放不下时回落 `eol`）、`virt_text_priority`（200）、`delay`（默认从 500 改成 1000）、
  `ignore_whitespace`（git `-w`）、`use_focus`、`extra_opts`；新增 `current_line_blame_formatter`
  （默认 `' <author>, <author_time:%R> - <summary> '`，与 gitsigns 逐字相同）与
  `current_line_blame_formatter_nc`（`' Not Committed Yet '`）。
- 占位符由新模块 `lua/vcssign/blame_formatter.lua` 展开：gitsigns 的同一份占位符表（`<author>`、
  `<author_name>`、`<author_mail>`、`<author_time>`、`<author_tz>`、`<committer*>`、`<sha>`、
  `<abbrev_sha>`、`<summary>`、`<previous>`、`<filename>`、`<lnum>`、`<orig_lnum>`、`<final_lnum>`）、
  日期 `:<strftime>`、`%R` 相对时间（`4 months ago`），以及**函数式 formatter**（可以返回 virt_text
  块）。适配器答不出的占位符原样保留（svn 没有 `<summary>`），所以默认格式另有一份
  `DEFAULT_NO_SUMMARY`。
- 装饰改成一个 extmark（`id = 1`，gitsigns 同款），文本同时写进 `vim.b.vcssign_blame_line` 与
  `vim.b.vcssign_blame_line_dict`。事件从「每缓冲区一条 autocmd」变成模块级 augroup（gitsigns 的
  `setup()` 形状）：`CursorMoved`/`CursorMovedI`/`BufEnter`/`WinResized` 刷新，`InsertEnter`/`BufLeave`
  清，`use_focus` 时再加 `FocusGained`/`FocusLost`，另外 `OptionSet fileformat,bomb,eol` 也清。
- 适配器面：git 的 porcelain 解析补齐 `author-mail`（去掉尖括号）/`author-time`/`author-tz`、
  `committer*`、`summary`、`filename` 与 **original line number**（`orig_lnum`）；`ignore_whitespace`
  走 `-w`，`extra_opts` 追加到命令行。svn 从 `<date>` 解析 `author_time`/`author_tz`（`<date>` 是
  UTC 的 `…Z`，而 `os.time` 按**本地**时区解释，所以要把偏移补回去）。
- 缓存键从 `changedtick` 扩成 `changedtick + ignore_whitespace + extra_opts`：同一个文件带与不带
  `-w` 是两个答案。
- 新增 `test/blame_formatter_spec.lua`（7 例，纯函数、不需要仓库），`blame_spec` 扩到 11 例
  （`virt_text = false`、`ignore_whitespace` 穿过空白改动、`use_focus` 不碰未聚焦窗口）。

### §6.2 怎么推进后续步骤（工作契约）

1. **路标就是 §6 的表**。一步一提交，标题沿用仓库既有风格：`feat(scope): 中文摘要（M6 Step N）` /
   `fix(scope): 中文摘要`；正文写**为什么这么改 + 实测数据**（不是逐条罗列改了哪些行）。
2. **每步的完成判据**：`make test` 全绿（**并额外把这一步动到的 spec 单独跑一遍**，如
   `FILTER=attach_spec make test`）+ `make format-check` 零输出 + `make lint` 0 警告 + 该步新面有 spec 覆盖。
   工具链与 M5 完全一致，**不新增依赖**。
3. **文档同步是硬约束**：`test/doc_spec.lua` 钉住「`config.defaults` 的每个键 / `cli.subcommands` /
   默认键位动作 / hunk 与高亮名 / 公共 API 名」都出现在 `doc/vcssign.txt` 里。**只要某一步动了这些面，
   必须同一步更新 `doc/vcssign.txt` + `test/doc_spec.lua`**，否则该步红。
4. **逐 SHA 复跑**（本仓惯例：工作树里常有下一步的在制品，而 `test/run.lua` 的 `DEFAULT_SPECS` 是各步共享的）：
   ```sh
   git stash push -u -- <下一步的文件…>        # 树里只留要验的那个提交
   git checkout <sha> && make test && git checkout main && git stash pop
   ```
5. **「不是本步问题」的缺陷单独开一个 `fix(...)` 提交**，放在功能提交之前（`f1d1735` 就是这么来的），
   不要混进功能提交 —— 这样 bisect 才有意义。
6. **验证要真跑**：新行为先写 spec（`guarded(fn)` 包住用例）。只有确实无法自动化的才写「手动实测记录」，
   探针脚本放 `temp/`（已 gitignore），**写完删掉**，别留噪音。

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/lua/pitfalls.md`

---

### §6.4 下一步（Step 13）的入口

**已经就绪、可以直接消费的接口**（`6eaef2b` 冻结，`2193802` / `4bfe0ce` 补齐开关与暂存层，`f54b6af` 补上导航与键位）：

- `require('vcssign.attach')`：`attach(bufnr)` / `detach(bufnr)` / `toggle(bufnr)` / `mark_dirty(bufnr)` /
  `refresh(bufnr, cb)` / `ready(bufnr, cb)`（等基线落地，必要时顺手启动管线；回调 `(err, st)`）/
  `refresh_all()` / `state(bufnr)` / `hunks(bufnr)` / `buffers()` / `root(bufnr)` /
  `system(bufnr)` / `capabilities(bufnr)` / `count()` / `forget_all()`。
  引用名是 `attach:<bufnr>`；每个缓冲区最多 attach 一次（按路径去重）。
  状态表（`state(bufnr)`）额外有：`hunks_staged`（git 的暂存层，`rev ~= 'index'` 时为空表）、
  `head_text` / `base_text`（两份基线，`nil` = 不知道，什么都不画）、`shown`（用户开关，Step 6）、
  `untracked` / `tracked` / `enabled` / `attached`。
- `require('vcssign.signs')`：`place(bufnr, hunks, opts)` / `clear(bufnr)` / `clear_ns(bufnr, staged)` /
  `sign_count(bufnr, staged)` / `namespace(staged)` / `hl_name(ty, staged, kind)` / `define_highlights()` /
  `sign_line(h)`（hunk 的 sign 行号，`nil` = 这一 hunk 没有 sign 行，`nav` 与 `place` 共用这一份规则）、`M.PRIORITY`。
- `require('vcssign.nav')`：`M.next(bufnr, count, opts)` / `M.prev(bufnr, count, opts)`（有向、带 count、
  `opts.wrap` 默认 true，**没有**键位配置项）/ `M.lines(bufnr)`（两层 sign 行号去重、排序、切到缓冲区范围内）。
- `require('vcssign.keymap')`：`M.attach(bufnr)` / `M.detach(bufnr)` / `M.dispatch(action, ctx)` / `M.ACTIONS`。
  未落地的动作走 `vim.notify_once(… is not implemented yet, WARN)`：Step 9–11 只要往 `M.ACTIONS` 里补一个
  实现（或让 `M.dispatch` 转发到 `actions`），对应键位就亮了，不用碰 `config.defaults.keymaps`。
- `require('vcssign.repo_manager')`：`get_by_path(path)` / `get(root)` / `all()` / `count()` / `ref_count(path)` /
  `on_repo_attached(fn)` / `on_repo_detached(fn)`。
- `require('vcssign.repo')`：`repo:on_update(fn)` / `repo:on_error(fn)` / `repo:on_delete(fn)` /
  `repo:mark_dirty()` / `repo:refresh_now(cb)` / `repo:dispose()`。

**Step 11 已经完成**（`22ad24a`）：`lua/vcssign/blame.lua`（`M.render(bufnr)` / `M.clear(bufnr)` /
`M.attach(bufnr)` / `M.detach(bufnr)` / `M.refresh_all()` / `M.namespace()` / `M.define_highlights()` /
`M.commit_text(bl)` / `M.line_text(bl)` / `M.line(bufnr, lnum, cb)`；命名空间 `vcssign_blame`，组
`VcssignBlame`，`current_line_blame_opts.delay` 去抖）与 `lua/vcssign/revdiff.lua`
（`M.text(rel, base_text, buf_lines)` / `M.show(t, text)` / `M.buffer(t)`）。`actions` 多了
`M.blame_line(target, opts)` / `M.diffthis(target, opts)` / `M.diffthis_rev(target, opts)`（原来的
`diff_buffer` / `show_diff` 已挪进 `revdiff`）；`preview` 多了 `M.open`；`attach` 的 `clear_layers` 与
`define_highlights` 调用都多了 blame 一层；`cli.M.subcommands` 现在是 13 项（多了 `diffthis` /
`blame_line`，注意 `diffthis` 的参数是 **rev 而不是路径**）；`keymap.ACTIONS` 里只剩
`setqflist` / `setqflist_all` 是占位提示。

**Step 12 已完成**（`a4b3551`）：早期计划的 `00`–`05` 加上了 M6 的「已退役 / M6 起已变」标记与 05 的实况表
（逐 spec 用例数与所需命令、`FILTER` 子集判据、两个要会解读的现象），07 §5.3 / §11 的 svn 结论与
`doc/vcssign.txt` 的三处措辞（`watch` / `retry_*` / `debug`）一并更正；用例数不变，`doc_spec` 6/6。
**早期计划的 `06` 与 `07` 的 §6 / §6.1 保持逐 SHA 记录，不当作「设计要求」读。**

**Step 14（终验 = M6 收尾，`a3e41fd`）**：五条判据全部落地。

1. **全量两遍幂等**：`sh scripts/run_tests.sh` 连跑两次，两次都 **`250 tests, 0 failed`**（退出码 0）。逐 spec 用例数
   （合 250）：`actions` 32 / `attach` 22 / `autocmds` 13 / `config` 7 / `diff` 10 / `doc` 7 / `exec` 13 / `hunk` 20 /
   `nav` 13 / `preview` 7 / `repo` 20 / `revdiff` 7 / `signs` 14 / `vcs_git` 14 / `vcs_registry` 8 / `vcs_svn` 13 /
   `worddiff` 9 / `blame` 8 / `cli` 13。
2. **stderr 合同**：stdout / stderr 分开重定向后，两次运行的 stderr **都只剩 `repo_spec` retry 用例那一行**
   （`exec_timeout_ms = 1` 的超时告警，无结尾换行，`wc -l` = 0）—— 就是 `05-testing-infra.md` 记的「0 或 1 行」。
   为此先清掉了 4 行测试自造噪音（`hs` 用例没包 `collect` 的通知、裸 `:write` 的文件名回显两行、
   `signcolumn = false` 的一次性告警、以及「删掉目录后留下文件已不存在的修改中缓冲区」导致的 `E211`），
   四个都改成了断言或显式清理（`a3e41fd`）。
3. **`git diff --check 080379c^..HEAD` 干净**；`make format-check` 零输出；`make lint` → `0 warnings / 0 errors in 46 files`。
4. **逐 SHA 复跑**（`temp/step14_rerun.sh`，每个提交 `git checkout <sha> && sh scripts/run_tests.sh`）：

| 提交 | 用例 | 结果 | 主题 |
|---|---|---|---|
| `080379c` | 125 | ✅ | refactor!: 退役侧边栏，改为行级 sign 骨架（M6 起点） |
| `3ecbdd7` | 128 | **❌ 3 failed** | refactor(repo)!: Repo 降级为元数据会话，exec 支持 |
| `5e8e485` | 158 | **❌ 2 failed** | feat(diff): hunk 模型与内置 diff 引擎（M6 Step |
| `7acc713` | 150 | **❌ 2 failed** | feat(vcs)!: 适配器改为基线文本 / 跟踪判定 / blame / |
| `f1d1735` | 150 | ✅ | fix(repo): 根目录加非递归 watch，工作副本被删时才可能发现 |
| `e6c4f1b` | 151 | ✅ | fix(vcs): svn 追踪判定改用 svn info，并更正 07 的 |
| `6eaef2b` | 178 | ✅ | feat(attach): sign 渲染与逐缓冲 attach 管线（M6 |
| `2193802` | 184 | ✅ | feat(attach): 自动触发、生命周期与逐缓冲开关（M6 Step  |
| `4bfe0ce` | 189 | ✅ | feat(signs): git 暂存态双层 sign（M6 Step 7） |
| `f54b6af` | 202 | ✅ | feat(nav): ]c / [c hunk 导航与默认键位（M6 Ste |
| `a5e544a` | 213 | ✅ | feat(actions): hunk 级暂存 / 撤销 / 丢弃与整缓冲区 |
| `5942dd9` | 213 | ✅ | fix(test): 把 repo_spec 的探针计数限定到被测仓库 |
| `1317890` | 229 | ✅ | feat(signs): 词级 diff 与 hunk 预览（M6 Step |
| `22ad24a` | 244 | **❌ 1 failed** | feat(blame): 当前行 blame 与 diffthis / re |
| `c2990be` | 250 | ✅ | fix(attach): 死状态复活、signcolumn 告警与默认键位的 |
| `a3e41fd` | 250 | ✅ | fix(test): 终验的 stderr 合同——把插件输出与 E211  |

   docs-only 提交（`9b4eb90`、`7f9a88d`、`0183ed4`、`11dcdf0`、`042a3b5`、`24555fb`、`2885291`、`1583f69`、`a4b3551`、`ea3b09e`、`8020245`）不单独复跑：它们的 Lua / test 树与父提交相同（`impl/` 与 `doc/vcssign.txt` 只被
   `doc_spec` 读，而 HEAD 的全量两遍已覆盖），代码状态由父提交的复跑覆盖。
   表里的 3 个红是**已知的 Step 2 回归**（`3ecbdd7` / `5e8e485` / `7acc713`）：`repo_spec: a vanished .git
   disposes the repository and frees every handle`（`test/repo_spec.lua:356`）与 `repo_spec: deleting an svn
   working copy cancels its watcher too`（`test/repo_spec.lua:378`）—— libuv 不报告被监听目录自身消失，
   `f1d1735` 用根目录非递归 watch 修掉，Step 2 的交接说明（§6.1）当时就记过。`22ad24a` 那 1 个失败**不可
   重复**：该 SHA 单独连跑两次都是 `244 tests, 0 failed`（与 §6.3 记的 `repo_spec` 元数据用例对负载敏感同源）。
5. **§7 验收对照**（10 条 → 断言它们的 spec）：

| §7 | 断言处 |
|---|---|
| 1 sign 逐行对位 | `signs_spec`（14）+ `attach_spec`（22，含屏幕单元格 `helpers.screen_line_at`） |
| 2 svn 工作副本同样显示 | `attach_spec` + `actions_spec` + `vcs_svn_spec`（13） |
| 3 编辑 / `:e!` / 外部改动 / `git add` 之后 200ms 内更新 | `autocmds_spec`（13，含 `BufWritePost` 与 reload）+ `attach_spec` |
| 4 git 暂存态第二层（不重叠） | `attach_spec`（4 例）+ `signs_spec`（高亮与 `place` 的 staged 层） |
| 5 `]c` / `[c` / `3]c` / 环绕 | `nav_spec`（13） |
| 6 `hs` / `hr` / `hS` / `hu`（含未保存拒绝、svn 能力门） | `actions_spec`（32）+ `cli_spec`（13） |
| 7 `word_diff` / `deleted_preview` / `:Vcssign preview_hunk` | `worddiff_spec`（9）+ `preview_spec`（7） |
| 8 `hb` / `current_line_blame` | `blame_spec`（8） |
| 9 `:Vcssign diffthis [rev]` | `revdiff_spec`（7） |
| 10 headless 断言 + `make` 全绿 + 文档一致 | 全量 250 + `doc_spec`（7）+ 本节 |

**M6 的交接**：里程碑到此结束，`main` 上 HEAD 的代码状态与本节记录一致。下一步的选择留给用户，
候选都在 §10 backlog（`diff.use_external`、`max_diff_lines`、rev 补全、内存内 patch、`:Vcssign setqflist`、
svn hunk 级丢弃的替代、`patch_of` 的基线新鲜度、`guarded` 收进 helpers）。**M6 期间刻意没做的三件事**
（D46：不引入 async 框架 / 不新增依赖 / 不动 D19）在 `09-*` 之后的任何一步都仍然有效。



## §7 验收标准（用户可点）

1. 打开 git 仓库里已修改的文件 → signcolumn 立刻逐行显示增/改/删/首行删/增删混合，与 `git diff` 的 hunk 一一对应；未跟踪文件整片 `┆`。
2. svn 工作副本里已修改的文件同样显示（基线 = `BASE`）。
3. 编辑缓冲区 → 200ms 内 sign 跟着更新；`:e!` 重载、外部改动、终端里 `git add` 之后 sign 也更新。
4. git 已暂存的行显示第二层（不同高亮）；同一行不会出现矛盾的两层 sign。
5. `]c`/`[c`（支持 `3]c`）在 hunk 间跳转，默认环绕（✓ `f54b6af` + `nav_spec` 13 例；
   **环绕不是配置键**（D44 —— §4 里没有这个键，gitsigns 也没有）：只有 `nav.next/prev(bufnr, count, { wrap = false })`
   这个 API 参数能关，用户在 `doc/vcssign.txt` 的键位表里读到的是「走到头会环绕」）。
6. `<leader>hs` 暂存当前 hunk（`git diff --cached` 可见）、`<leader>hr` 丢弃当前 hunk（磁盘回到 index 版本；缓冲区有未保存修改时拒绝并提示）、
   `<leader>hS` 暂存整个缓冲区、`<leader>hu` 撤销暂存；svn 侧丢弃按能力门给明确结果。
7. `word_diff` 打开后 change hunk 的行内改动高亮；`deleted_preview` 打开后被删行以 `virt_lines` 内联显示；`:Vcssign preview_hunk` 弹窗显示完整 hunk。
8. `<leader>hb` 显示当前行 blame；`current_line_blame` 打开后随光标显示虚文本。
9. `:Vcssign diffthis [rev]` 与任意 rev 比对。
10. 以上交互都在 headless 测试里被断言（含屏幕单元格）；`make test lint format-check` 全绿；
    `doc/vcssign.txt` 与 早期计划的 `07-*.md` 与实现一致。

---

## §8 风险与回落

- **`vim.text.diff` 行为与 gitsigns 的外部 diff 有差异**（换行/上下文处理）→ hunk 对位用例以「真实 `git diff` 的 hunk 列表」
  为基准比对；差异记入本文，必要时为个别场景保留外部 diff 回退位（D39 的 `use_external`）。
- **svn 无法做 hunk 级 revert** → 落 tempname 临时补丁（`svn patch --strip 0`）；若反向补丁也不可用，
  该能力报「不支持」并只提供整文件 `svn revert`（能力门 + 明确提示）。
- **`signcolumn=no` 的缓冲区看不见 sign** → 用户自己把 `'signcolumn'` 设成会显示的值（Neovim 默认 `auto` 就行）；插件不代设窗口选项（M6 之后对齐 gitsigns，见 §6.1 末条）。
- **大文件/超长行** → `max_file_length` 拒绝 + 计数上限；word-diff 只在 hunk 行内做（§5.6 有耗时数据）。
- **CRLF / autocrlf** → `exec` 的 `text=true` 归一 + `ignore_cr_at_eol`；专门用例（Step 3）覆盖。
- **`Repo` 收敛会挪动 spec 计数与 stderr 合同** → Step 2 内同步改 `05-testing-infra.md` 与 `02-repo-runtime.md` 的计数/stderr 声明。
- **减法步骤（Step 1）面较大** → 它的判据就是「删干净 + 全绿 + 文档/`doc_spec` 同步」。

---

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/ecosystem/prior-art.md`

---

> 本节已抽取到（归档后不再维护）：
> - `loop/workspace/signs/2026-10-16T23-59-34-backlog-signs-and-diff.md`

---

> 本节已抽取到（归档后不再维护）：
> - `loop/workspace/signs/2026-10-16T23-59-34-backlog-signs-and-diff.md`
> - `loop/knowledge/vcs/svn-output-formats.md`
> - `loop/workspace/testing/2026-10-16T23-59-34-backlog-ci-and-test-hygiene.md`
>
> 第 2 条（`svn patch --strip`）的事实已并入 svn 知识文档；第 5 条（`svn blame` 大文件耗时）在 testing 任务文档。

---

## §12 不做什么

- 不引入 gitsigns 的 async 框架（保持回调链 + 错误优先契约）。
- 不做 qflist / diff-against-worktree 之外的额外命令（`:Vcssign setqflist`、`toggle_deleted`、`select_hunk`、`:Gitsigns` 那类导航子命令族）——列入 backlog。
- 不改 D19（回调在主循环）、不改引用计数（D18）、不新增依赖、不改 M5 的工具链（`stylua`/`luacheck`/`Makefile` 沿用，新文件同样 `make format-check lint`）。
