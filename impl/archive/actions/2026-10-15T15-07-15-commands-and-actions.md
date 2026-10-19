# 用户命令、动作与 autocmd 生命周期（actions）

> **模块** `actions`（`impl/archive/actions/`）· **状态** 已实现（M7 步骤 5 修订过动作层）· **原编号** 04

> **⚠ M6 起交付物表与子命令集已变**：侧边栏退役后 `:Vcssign` 只剩 13 个子命令（`toggle` /
> `refresh` / `stage_hunk` / `undo_stage_hunk` / `reset_hunk` / `stage_buffer` / `reset_buffer` /
> `preview_hunk` / `diff` / `diffthis` / `blame_line` / `commit` / `debug`），autocmd 从「按仓库挂载」改成
> 「按缓冲区 attach」，动作层的落点也从「状态行」变成「缓冲区里的 hunk」。`open` / `close` / `get_status` /
> `get_entries` 与 §2 的键位表是 M4 的记录；当前实现与验收见 `impl/knowledge/signs/2026-10-16T11-43-18-signs-in-signcolumn.md`。

> UI 就绪后的最后一层能力：把 `vcs` / `runtime` / `sidebar` 的模块串成「一键可用」的入口
> （`:Vcssign` 命令族、自动 attach、动作分发）。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `lua/vcssign/cli.lua` | `:Vcssign` 子命令分发 + 命令补全 |
| `lua/vcssign/actions.lua` | 动作层：open / diff / stage / unstage / commit / refresh（按 capabilities 分派） |
| `lua/vcssign/autocmds.lua` | 生命周期 autocmd（attach 触发、清理） |
| `plugin/vcssign.vim` | 只做命令注册（`nvim_create_user_command`，回调/补全都写成「用时才 `require`」）；`setup()` 仍由用户显式调用 |
| `lua/vcssign/init.lua` | 公共 API：`setup` / `open` / `close` / `toggle` / `refresh` / `get_status` / `get_entries`（§5） |

## 2. 动作层（actions.lua）—— 按 VCS 能力分派

能力声明（vcs 的 base 接口）：

```lua
---@class vcssign.VcsCaps
---@field stage boolean       # git: true, svn: false
---@field unstage boolean     # git: true, svn: false
---@field commit boolean      # 两者 true
---@field diff boolean        # 两者 true
```

所有动作签名统一（单 repo 上下文；无参时默认作用于 `renderer.item_at` 当前条目）：

```lua
actions.open(entry)          # :e / tabopen 文件（deleted/missing 状态跳转时提示）
actions.diff(entry)          # diff 展示（见 §2.1）
actions.stage(entry)         # capability gate → system.stage(root, {entry.rel_path})
actions.unstage(entry)       # git only
actions.commit(...)          # 见 §2.2
actions.refresh()            # Repo:refresh
```

完成后的统一收尾：动作成功 → 触发 `Repo:refresh()`（强制拉新，staging 会翻转状态）；失败 → `vim.notify(err, ERROR)`。

> **M7 步骤 5 修正（perf P1-1/§2.9）**：**hunk 级**的 `stage_hunk` / `unstage_hunk` 只留
> `attach.refresh(bufnr)`，不再同时 `repo:refresh_now()`——索引写自身会产生 fs 事件，去抖之后
> 那次探测就够了；两条路径并存等于一次动作两次刷新（实测应答时进程 4 → 3，`hs` 后立刻 `hu`
> 仍作用于刚更新的层）。`commit` / `stage` / `unstage`（整文件）**仍用 `refresh_now`**：它们没有
> 「下一个动作要读屏幕上的层」这个约束，也没有索引事件之外的刷新手段。
> 另：`has_staged_change` 改成先问仓库的 status 视图（`Repo:status` 的 `trusted` 为真时），
> 视图不可信才回退两次整文件 `show`（commit 一个已 stage 文件 5 → 3 进程、`show` 2 → 0）。**所有动作走 runtime 的 exec 封装**，UI 层（sidebar keymap）只调 actions，层次干净。

### 2.1 diff 展示

`diff.mode`（config）决定 diff 窗口开在**哪一侧**：`"vertical"`（默认）是右侧竖分屏，`"split"` 是下方横分屏。
diff 灌进一个 nofile 缓冲区、`filetype=diff` 交给内置语法上色：

- git：`git --no-pager diff --no-color HEAD -- <file>` 取 unified diff → 借鉴 vcs-helper `systems/base.lua` 的 `parse_diff_hunk`（unified diff 解析已成参考）**但不引入它的渲染**——更简单的方案：diff 输出直接灌进一个 `vcssign-diff` nofile 缓冲区，`filetype=diff` 让内置 syntax 上色，这是初版方案。
- 与暂存内容对比：`git diff --cached -- <file>`——当条目的改动**只在 index 里**（`index ~= nil and worktree == nil`）时用它，
  因为那才是「这次提交会记下什么」；只改了工作区（含 `AM`：已暂存之后又改过）时对比 `HEAD`，回答的是「相对上次提交改了什么」。
  未提交的仓库（没有 `HEAD`）由适配器回落到 `--cached`。
- svn：`svn diff -- <file>` 同上灌缓冲区（svn 没有 index，第二个参数被忽略）。
- 缓冲区名 = 侧边栏 bufname + `/` + `rel_path`：同一个文件再按 `d` 会**复用缓冲区与窗口**，不会堆一摞分屏；
  缓冲区 `modifiable = false`、`bufhidden = wipe`（diff 是视图不是文档）。
- 没有任何改动可显示时（`git diff` 输出为空）只提示 `no changes to show`，不开一个空窗口。
- 后续增强（列 backlog，不进初版）：左右窗 worktree vs HEAD 对比（gitsigns `actions/diffthis.lua` 是参考）。

### 2.2 commit

- `vim.ui.input` 取单行 message（config `commit.message_input = "input" | "buffer"`，初版只 `"input"`；`"buffer"`= 临时缓冲区提交，gitsigns `actions/commit.lua` 是参考，backlog）。
- git：选中文件先确保 staged（在 Staged 组的条目直接 `git commit -m msg -- <files>`；跨组混合提交初版**禁止**——提示先 stage）。
- svn：`svn commit -m msg -- <files>`。
- 提交后强制 refresh；失败原样 notify（svn 服务端连接错误的 stderr 有价值，整段展示）。
- 取消输入（Esc）**什么都不做也不说话**；提交空白消息只回一句 `empty commit message: nothing was committed`（两种都不提交）。
- **非普通文件的条目直接拒绝**：svn 会把目录本身列成条目，而 `svn commit -- <dir>` 默认递归提交整棵子树——那比用户
  指的那一行多得多。提示 `is not a file: commit its files one by one`，不做任何提交（`diff` 对目录保持子树 diff，
  它只是看，不写）。
- 消息来源：`vim.ui.input`（`commit.message_input = "input"`）；`"buffer"` 未实现，会 `log.warn` 后回落（同
  `sidebar.position = "float"` 的处理）。
- git 的「必须先 stage」判定按**能力**而不是按名字：`capabilities.stage` 为真的系统，`status.index == nil` 就拒绝；
  svn（`capabilities.stage = false`）直接提交工作副本。

## 3. `:Vcssign` 命令族（cli.lua + plugin/vcssign.vim）

仿 gitsigns `:Gitsigns`（`cli.lua` 的子命令分发 + 补全），但去掉它的 argparse 通用化（初版不需要 `key=value` 参数解析，只做 `- nargs="*" -complete=customlist`）：

| 子命令 | 效果 |
|--------|------|
| `:Vcssign toggle`（默认，无参） | 侧边栏 toggle（sidebar §2 语义） |
| `:Vcssign open [path]` | 打开 path（默认当前文件/cwd）所属 repo 侧边栏 |
| `:Vcssign close` | 关闭 |
| `:Vcssign refresh` | 强制刷新当前 repo |
| `:Vcssign diff [path]` | 与 `d` 同一动作（计划表里只有按键，命令补上是为了一次性可用） |
| `:Vcssign stage [path]` / `unstage [path]` | 动作层入口（git only） |
| `:Vcssign commit [path]` | §2.2（路径是文件，消息一律来自输入框） |
| `:Vcssign debug` | 打印当前 repo 状态缓存 + 监听句柄数（排障用，gitsigns `:Gitsigns debug_messages` 的定位） |

补全：`customlist` 枚举子命令（gitsigns `cli.complete` 的简化版）；`stage/unstage` 补全当前条目 rel_path 可后置，初版只补子命令
（实测：`-complete=customlist` 无法同时做文件名补全，所以 `:Vcssign stage ` 之后返回空集）。
切词后按**单个空格**拼回，因此未转义的**连续**空格会塌成一个（`:Vcssign stage 'a  b.txt'` 要加引号）。

路径参数：`<f-args>` 按空白切词，所以未加转义的空格路径会拆成多个词——命令把剩下的词**拼回一个路径**
（`:Vcssign stage my file.txt` 可用）。无参时指向「光标所在侧边栏行 → 当前缓冲区文件 → cwd」。

`plugin/vcssign.vim` 只做 `nvim_create_user_command("Vcssign", ...)`，实现体 `require("vcssign").cli.run(params)`——保持 gitsigns 的「plugin/ 最薄」惯例。

## 4. autocmds.lua —— 生命周期

一个 augroup `vcssign`（gitsigns attach.lua 的 group 模式）：

| 事件 | 处理 |
|------|------|
| `BufReadPost` / `BufEnter`（filetype 非 vcssign 的普通文件） | `repo_manager.attach(expand("<afile>:p"))`（runtime 会话内幂等） |
| `DirChanged`（global/cwd） | 重新探测 cwd 的 repo；attach（当前文件 repo 不变则无事） |
| `FocusGained` | `Repo:refresh()`（兜底：外部编辑器/终端改文件，Windows 上的可靠兜底） |
| `VimLeavePre` | 全 repo `dispose()`（runtime §4 清理路径） |
| `OptionSet signcolumn`（可选） | 不处理（窗口内强制 `signcolumn=yes:2`，见 sidebar §2） |

`setup()` 时创建 group；`config.on_attach` / `on_detach` 回调钩子（gitsigns config 同款命名），给用户集成点。

> **⚠ M6 Step 6（`2193802`）**：`autocmds._attached` 已经删掉 —— 「只 attach 一次」现在由
> `attach.lua` 按路径去重（同一个文件的第二次 `attach(bufnr)` 直接返回既有状态、不跑探测），
> 所以 `BufEnter` 可以无脑重复调用。下面这段是 M4 的记录。

去抖：**改用「每个缓冲区只 attach 一次」的记忆表**（`autocmds._attached[bufnr] = path`），不再在
`repo_manager` 内部套 `debounce_trailing(100ms)`（偏差见 §7.1）：风暴的本质是同一个缓冲区被反复进入，而
`repo_manager.attach(ref, path)` 对同一 `(ref, path)` 本来就幂等；加一层防抖反而会把「打开文件后的第一次
attach」也推迟 100ms——那一次正是用户在等的。

另外：`VimLeavePre` 只做清理（`sidebar.forget_all()` → `manager.dispose_all()`），**不杀正在跑的 VCS 命令**：
`exec` 的超时定时器要等子进程回答才关（§7.1 记了这条边界）。

## 5. 公共 API（lua/vcssign/init.lua）

```lua
require("vcssign").setup(opts)          # 合并到默认值（不累积）+ 默认高亮 + autocmd 建组
require("vcssign").refresh([path])
require("vcssign").open([path]) / close() / toggle()
require("vcssign").get_status(path)     # 单文件状态（第三方集成入口，对标 gitsigns 的 b:gitsigns_status_dict 角色）
require("vcssign").get_entries([path])  # 该仓库的全部条目（侧边栏看到的那份）
```

- 无参时 path 依次取「光标所在侧边栏的仓库 → 当前缓冲区文件 → cwd」；仓库还没被跟踪时这几个 API 会先
  `ensure` 一把（所以第一条命令/第一次调用就能用）。
- `get_status` / `get_entries` **只读缓存、不阻塞**：路径所属仓库还没跟踪就返回 nil / `{}` 并在后台预热
  （同一路径同时只允许一次预热），答案由下一次调用给出。它们按**最近的 marker** 解析仓库（与 `ensure` 同一规则），
  所以嵌套仓库不会被父仓库的缓存冒充。
- 「没有仓库」这一句由 `vcssign.cli.report_no_repo` 统一发出：命令层与公共 API 的措辞、级别完全一致。

`get_status` 保证「不在仓库返回 nil，仓库存在但未刷新不阻塞」（直接返回缓存，nil 时后台触发 attach+refresh）——供 oil-vcs-status 这类集成未来消费（backlog，见 overview 非目标）。

## 6. 验收标准与实测结果（M4 完成）

全部有自动用例（`test/actions_spec.lua` 24 + `test/cli_spec.lua` 17 + `test/autocmds_spec.lua` 10，另加
`test/exec_spec.lua` 的 2 条定时器不泄漏），全量 167/167；stderr 只有 1 行预期的重试告警。

| # | 计划验收 | 用例 | 实测 |
|---|----------|------|------|
| 1 | 非 VCS 目录下 `:Vcssign toggle` → INFO 级 `no repository found`，不报错 | cli_spec「outside every repository it says so, at INFO level」 | ✅ INFO，消息里带被查的路径；「没仓库」与「环境坏了」（缺二进制、权限）分开报（后者 ERROR） |
| 2 | git 全链路：toggle → `s` stage → 状态翻到 Staged → `u` unstage → `commit` 后列表清空 | actions_spec「stage …」「unstage …」「commit commits a staged file …」 | ✅ 每步都用 VCS 自己核对（`git diff --cached --name-only`、`git log -1 --format=%s`、`rev-parse HEAD`），不只看插件缓存 |
| 3 | svn：stage/unstage 不生效并提示；commit 成功；列表清空 | actions_spec「svn has no staging area …」「svn commits the working copy …」 | ✅ 提示 `svn: no staging area`（无 `vcssign:` 前缀，与键位层同一句式）；提交后 `svn log -l 1 <url>/trunk` 能查到 |
| 4 | 外部修改经 FocusGained 与 fs 监听两条路都能带进侧边栏 | autocmds_spec「FocusGained refreshes …」+ M2 的 fs 监听用例 | ✅ 直接驱动 `nvim_exec_autocmds('FocusGained')`（headless 收不到终端焦点事件）；fs 一路由 M2 用例覆盖 |
| 5 | `VimLeavePre` 后无残留 uv handle | autocmds_spec「VimLeavePre leaves no repository, sidebar or watcher behind」 | ✅ 无仓库、无侧边栏、`fs_event = 0`、`timer = 0`（**先等首次 status 落地**，见 §7.1 的边界） |
| 6 | 命令补全列出全部子命令 | cli_spec「completion offers the subcommands …」 | ✅ 空前缀给全量、前缀过滤、子命令之后返回空（`customlist` 不能补文件名） |
| 7 | （额外）命令能在**什么都没 attach** 的新会话里用 | cli_spec「the command works before anything has attached the repository」 | ✅ `manager.ensure` 会先探测并 attach；同一路径重复命令不累积引用 |
| 8 | （额外）`plugin/vcssign.vim` 真的注册了命令 | cli_spec「plugin/vcssign.vim registers the command and it runs」 | ✅ `source plugin/vcssign.vim` 后 `exists(':Vcssign') == 2`，`Vcssign debug` / `Vcssign toggle` 都通 |

**没有被验收覆盖的**：`:Vcssign commit` 在**命令行**上的完整交互（用例走 `actions.commit` + 桩 `vim.ui.input`，
命令一层由「每个子命令都能分派」+ `stage` 的路径解析覆盖）。

## 7. 实测、偏差与坑

### 7.1 与计划不同或计划没说清的地方

1. **attach 去抖改成「每缓冲区一次」记忆表**（§4）。理由：风暴来自同一缓冲区反复 `BufEnter`，而
   `attach(ref, path)` 本身幂等；防抖会连「第一次 attach」一起推迟。代价：换缓冲区不会重新探测——但那条路由
   `DirChanged` / 显式命令覆盖。
2. **`exec` 的超时定时器改成「先建表再 spawn」**。计划（及 M1 实现）是 spawn 之后再建定时器并 `start`，
   而实测发现 `vim.system` 的退出回调**可能在本函数返回之前**就跑（`cwd` 不存在这种立刻失败的进程），
   于是那次 `finish` 看到的是 `timer = nil`，定时器被留在「已武装」状态直到 15s 后超时才自我关闭——
   期间是一个活着的 handle（`autocmds_spec` 的 `VimLeavePre` 用例抓到的就是这个）。
   改成定时器在 spawn 前建好，`finish` 就一定能关掉它；`proc` 先声明为局部变量，超时回调里判空后再 `kill`。
3. **`repo_manager.ensure(path)` 新增**（§3 的路径解析靠它）。它按**最近的**仓库 marker 解析，而不是
   `get_by_path` 的「最深的**已 attach** 仓库」——后者在「仓库套仓库」（子模块、vendored checkout、
   项目里放测试仓库）时会把内层文件判给外层仓库，于是侧边栏和 stage 都作用在错误的树上。
   顺带：`ensure` 现在对 nil 路径直接 `assert`，因为 `base.normalize(nil)` 会静默变成
   「cwd 下的相对路径」（实测得到一个 `v:/null` 这样的字符串）。
4. **`:Vcssign` 多了一个 `diff` 子命令**（计划表只列了按键）：动作既然有了，命令族不该缺一个入口。
5. **`plugin/vcssign.vim` 用 `nvim_create_user_command` + 惰性 `require`**：命令回调与补全函数都写成
   「用时才 `require('vcssign.cli')`」，这样 `plugin/` 在启动时只执行一行注册、不加载 Lua 模块树。
6. **`commit.message_input = "buffer"` 与 `diff` 的更花哨形态（左右窗对比）**留在 backlog：前者会 warn 后回落
   到 `input`，后者没实现。
7. **`repo_manager.ensure` 的引用是「会话级、每仓库一个」的**：显式命令（`:Vcssign open` 等）用
   `cmd:<root>` 把仓库钉住到退出（用户明确要求用它），所以第二个命令不会再加一个引用，也不会因为换了文件而
   取消前一个的探测。`get_status` 的预热用的是共享的 `get_status` 引用——只读窥视不该按路径钉住一堆仓库（那会
   给每个查过的目录都挂一个监听）；代价是预热第二个仓库会放开第一个（如果没有别的持有者），集成方可以自行
   `manager.detach('get_status')`。
8. **侧边栏自己持引用**（D18 原文），`sidebar:<system>|<root>`：缓冲区活多久就持多久。M4 之前只有缓冲区/命令
   持引用，于是「关掉仓库里最后一个文件缓冲区」会把用户正在看的侧边栏一起拆掉（M4 审查抓到的 major）。
9. **动作条目按「身份」绑定仓库**：`entry.rel_path` 是**渲染它的那个 root** 的相对路径，所以仓库套仓库时
   （外层把内层 checkout 列成一行 `?? inner/`）不能用「包含该路径的最深仓库」来解析——那会把外层的相对路径交给
   内层仓库，stage/diff 作用在错误的树上。解析时按 `abspath(repo.root, entry.rel_path) == entry.path` 精确匹配
   （review major）。

### 7.2 计划里应当记住的坑

1. **Lua 模式没有多行锚点**：`text:find('^%+changed$')` 里 `^`/`$` 只匹配整个字符串的首尾，对多行 diff 等于
   什么都没断言（写用例时被这个骗过一次，改成逐行比较）。
2. **`svn log` 在工作副本上只到 BASE 版本**：刚提交完还没 update 时，`svn log -l 1 <wc>` 看不到那次提交，
   要用 URL（`svn log -l 1 <url>/trunk`）。
3. **提交类用例不能打共享 fixture 的主意**：`temp/svn-server` 是只读的（多个 spec 断言它的状态矩阵），
   所以 `helpers.svn_repo(name)` 现造一个 `svnadmin create` 的服务器 + 工作副本，都落在 `temp/_spec/` 下由
   `cleanup()` 删掉。
4. **`vim.ui.input` 是回调式的**，桩要连「取消」（回调收到 nil）和「空串」两种都覆盖；两者都不该提交。
5. **headless 里 `FocusGained` 永远不会来**（和 `VimResized`/`WinResized` 一样），用例必须用
   `nvim_exec_autocmds` 驱动——驱动的是同一个处理器，注册本身另有用例断言。

### 7.3 backlog（本里程碑不做）

- `commit.message_input = "buffer"`：临时缓冲区写提交消息（gitsigns `actions/commit.lua` 是参考）。
- 多选/整组 stage（`:Vcssign stage` 目前一次一个文件）。
- diff 的左右窗模式（worktree vs HEAD 并排）、word diff。
- `:Vcssign` 的路径参数补全（需要 `-complete=file` 之外的自定义实现）。
- 未跟踪文件的 `d`：`git diff HEAD` 对 untracked 永远是空，用户想看的是「新文件全文」。
  实现路径是 `git diff --no-index`（Windows 上 `/dev/null` 的等价物要单独处理），不是一行能改对的。
- 补全在带范围/缩写前缀时（`:1,5Vcssign st`）返回空集：`cmdline` 的形态比 `Vimcssign <word>` 多，需要更细的解析。

## 7.4 M4 独立审查（code-reviewer）与修复

范围 `318e1b3..1f3ed6e`，结论 **无 critical，2 major + 约 20 minor**；逐条核实后的处置：

| 级别 | 发现 | 定论与动作 |
|------|------|-----------|
| major | `actions.resolve` 对侧边栏条目用「包含该路径的最深仓库」重查，却沿用另一个 root 的 `rel_path` | **成立，已修**：改成按身份精确匹配（`abspath(root, rel_path) == path`），用例「an entry is acted on in the repository that listed it」用「外层仓库 + 内嵌仓库」真实复现 |
| major | 侧边栏不持 manager 引用（D18 没落地），`ensure` 的已跟踪分支也不加引用 → 关掉最后一个文件缓冲区会把用户正看着的侧边栏拆掉 | **成立，已修**：新增 `repo_manager.hold(ref, repo)`，侧边栏用自己的 `sidebar:<system>|<root>` 引用；`ensure` 的引用改成「每仓库一个」；`sidebar_spec` 那条用例改成同时钉住「侧边栏保命」与「会话teardown 才拆」 |
| minor | `get_status`/`get_entries` 用 `get_by_path`（最深已 attach），与命令层的 `ensure`（最近 marker）不一致 | **成立，已修**：两处都按最近 marker 解析；用例「a nested repository is not answered with its parent cache」 |
| minor | `get_status` 的共享引用会互相解绑；同一路径连续冷查询会重复探测 | **部分修**：共享引用保留（只读窥视不该按路径钉住一堆仓库，见 §7.1 #7），但同一路径在飞的预热只发一次；文档写明取舍 |
| minor | 公共 API 与命令层对「没仓库」的级别/文案不一致（INFO vs 分类报错） | **成立，已修**：抽出 `cli.report_no_repo`，两边共用；新增用例断言公共 API 也是 INFO + 带路径 |
| minor | `ensure('')` / `ensure(nil)` 走 `assert`，从公共 API 传入会抛裸断言 | **成立，已修**：`cb('no path given')` 走正常错误通道（用例覆盖） |
| minor | `is_definitive_negative` 不认插件自己造的 `no repository for X`、也不认 svn 的 `W155007` | **成立，已修**：清单补齐 |
| minor | `cli.register` 是死代码，且与 `plugin/vcssign.vim` 的内联注册文案不一致 | **成立，已删**：注册只在 `plugin/vcssign.vim`（那里能惰性 `require`） |
| minor | `:vsplit` / `nvim_open_win` 没 `pcall`，失败会在异步回调里以 `Error in callback` 冒出来 | **成立，已修**：两处 `pcall` + `fail()` |
| minor | `editor_window` 只排除 `filetype == 'vcssign'`，终端/quickfix/浮窗会被 `:edit` 顶掉 | **成立，已修**：只接受 `buftype == ''`、非浮窗的普通窗口 |
| minor | svn 目录条目上 `commit` 会递归提交整棵子树（比用户指的那一行多） | **成立，已修**：非普通文件直接拒绝并说明；用例用 `svn mkdir` 造目录行复现 |
| minor | 没有 `HEAD` 的仓库（unborn）按 `d` 报 `ambiguous argument 'HEAD'` | **成立，已修**：git 适配器回落到 `--cached`（那才是「首次提交会记下什么」） |
| minor | diff 文本尾部多一个空行 | **成立，已修**：`vim.split(..., trimempty = true)` |
| minor | `DirChanged` 用 `uv.cwd()` 且不区分 `:lcd`/`:tcd`，会把 `cwd` 引用绑到无关仓库 | **成立，已修**：读 `v:event.scope`（只处理 `global`）+ `v:event.cwd`；用例补 `:lcd` 不该重绑（**注意**：这个事件的细节在 `v:event` 里，不在回调参数上——第一次改错成 `args.scope` 被用例抓住了） |
| minor | `VimLeavePre` 里 `sidebar.forget_all()` 若抛异常（侧边栏是唯一窗口 → `E444`）会跳过 `dispose_all()`，句柄全留 | **成立，已修**：`pcall(sidebar.forget_all)` + `drop()` 内关窗也 `pcall`；用例「teardown survives a sidebar that is the last window」 |
| minor | `exec` 定时器顺序的修复没有专门回归用例 | **成立，已补**：新用例用**同步回调**的桩复现（旧实现下会剩一个已武装 timer，实测会红） |
| minor | 测试卫生：三份 spec 各抄了一份 `collect`；`actions_spec` 的 `reset()` 不 `cd` 回来；「静默」用例没断言静默；新代码若干分支无用例 | **成立，已修**：`collect` 收敛成 `helpers.capture_notify(fn, is_done?)`；`reset` 复位 cwd；静默用例改为断言 `#seen == 0`；补了「全是侧边栏时的 `open`」「VCS 拒绝的 diff」「`message_input = "buffer"` 回落」「`ensure` 引用不累积」等用例 |
| minor | 文档漂移：§1 说 plugin 文件是「setup 延迟加载入口」、§5 API 列表漏 `get_entries`、§6 计数、§2.2 文案、注释引用了不存在的 §6.1 | **成立，已修**（本节及 §1/§2/§3/§5/§6 均已按代码校正） |
| minor | `commit.message_input` 非 `input` 时每次提交都 warn；`setup()` 不累积 opts | **保留**（与 `sidebar.position = "float"` 每次 open 都 warn 一致；`setup()` 的语义改在 docstring 里写明，不再让人猜） |
| minor | 未转义**连续**空格路径会塌成一个空格 | **保留（已声明）**：§3 写明要加引号 |
| minor | `autocmds_spec` 的 `REQUIRES` 列了用不到的 `svn` | **成立，已修** |
