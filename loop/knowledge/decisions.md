# 架构决策记录（D1–D48 摘要索引）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` §4（D1–D37）与
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §2（D38–D48）。原文抽取，未做改写。

**要点**：D1–D37 定下 M0–M5 的骨架——回调链而非 async 框架、`Repo` 只在主循环操作、引用计数、
不新增依赖、`lua/vcssign/vcs/<name>.lua` 适配器 + registry、侧边栏退役前的 UI 契约等。
D38–D48 是 M6 行级 sign 的决策：`Repo` 降级为「仓库会话」（D38）、内置 `vim.text.diff`（D39）、
hunk 类型与 gitsigns 对齐 + 双命名空间（D40）、patch 走 stdin（D41）、基线 = `rev`（D42）、
行尾统一（D43）、键位与 gitsigns 同形（D44）、reset 保护未保存改动（D45）、不引入 async 框架（D46）、
`culhl` 用原生 `cursorline_hl_group`（D47）、`setup()` 补扫窗口缓冲区（D48）。

流水线（M6 Step 12 之后）**代码即事实**：本表只解释「为什么」，不描述现状；现状看 `lua/vcssign/`。

---

*来源：`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md`，原文 `## 4. 关键决策（ADR 摘要）`*（标题层级已下移一级）

### 4. 关键决策（ADR 摘要）

| # | 决策 | 理由 |
|---|------|------|
| D1 | 最低 Neovim 0.10，进程统一走 `vim.system`（async + `text=true`） | 免移植 gitsigns 自研 async；`vim.system` 在 0.10 稳定，跨平台、支持 cwd/env |
| D2 | VCS 抽象采用 **接口表（base.lua）+ 每系统一个模块**，接口含 emmylua 元类型定义 | vcs-helper 验证过的最小模式；状态解析必须以 `root` 为参数（修正 vcs-helper 的 getcwd 缺陷） |
| D3 | git 状态获取用 `git status --porcelain=v1 -z --untracked-files=all`（NUL 分隔） | 彻底绕开空格路径 / `core.quotepath` 引号问题；解析器按 `-z` 协议写（01） |
| D4 | root 检测：git 用 `git rev-parse --show-toplevel`，svn 用 `svn info --show-item wc-root`，均带**关键字文件向上扫描的同步兜底** | 命令是权威（正确处理 worktree / `.git` 为文件的情况）；同步兜底覆盖命令不可用/首次快速探测 |
| D5 | 每仓库一个 `Repo` 对象，状态缓存为 `path → {index, worktree}`（原计划写 `upstream/local`，见 D11）；FS 监听（去抖）只置脏，统一经 `refresh` 防抖管线拉取 | oil-vcs-status 的成熟模式；避免监听回调里直接跑命令造成风暴 |
| D6 | 侧边栏 = 专属 nofile 缓冲区（`vcssign://<system>/<root>`）+ 可配置 `right/left/float` 窗口；每行**两个 extmark sign 位**（index/worktree）+ 行文本 | 双状态列与 oil-vcs-status 一致；extmark 比 `:sign` 好清理（一个 namespace `clear` 即可） |
| D7 | 状态枚举以 oil-vcs-status 的 `StatusType` 为基础精简为「核心 + upstream 前缀」两族；svn 特有状态（replaced/missing/switched/external）单列 | 见 01 §2 统一映射表 |
| D8 | 动作按 VCS 能力声明：适配器暴露 `capabilities = { stage=true, diff=true, commit=true … }`，UI/命令按能力启用 | svn 无暂存区；避免 UI 层 if git / if svn 散落 |
| D9 | 按仓库并发刷新用「串行化队列 + 防抖」（gitsigns `throttle_async` 思路的回调简化版），`in_flight` 标志防重入 | 监听风暴 + 手动 refresh 同帧触发时不会并发跑同一 repo 的 status |
| D10 | 测试仓库放 `temp/`（用户提供的位置）；由 `scripts/make_test_repos.sh` 幂等生成 git / svn 两个仓库，fixture 状态可复现 | 已实测：从零重建 + 连续两次跑均正确（05） |
| D11 | 状态字段命名用 `index` / `worktree`（不用原计划的 `upstream` / `local`） | `local` 是 Lua 保留字，`status.local` 是语法错误（已实测）；`index`/`worktree` 正是 git porcelain 自己的术语 |
| D12 | 所有回调 **错误优先** `cb(err, ...)`，包括 `get_root_async` / `detect_async` | 避免了计划原稿中回调签名不一致导致的错位取值（实现时真踩过） |
| D13 | 测试不引入 `nvim-test`，自研 TAP 输出 runner + 阻塞式 `helpers.wait`；断言用全局 `ok/eq/check` hard-fail | Windows 下零依赖；阻塞式等待让异步管线可以写成同步顺序代码（05 §3） |
| D14 | **去抖只做一层**：FS 回调直接 `mark_dirty()`，去抖由管线的 `debounce_trailing(300ms)` 负责（取消原计划的「FS 路径 timer 池」） | 两层串联 = 600ms 延迟 + 两套定时器要去清；实测一次 `git add` 只有 ~12 个事件，一层完全够（02 §3.3） |
| D15 | 监听集 = `root`（非递归）+ **root 的直接子目录**（非递归）+ marker（非 Linux 递归）；只展开一层 | 只监听 root 会漏掉子目录里的编辑（最常见场景）；全量递归在 Linux 上根本不可用、在大仓库上代价高（02 §3.2） |
| D16 | `Repo` 的**每个** uv 回调都 `vim.schedule_wrap` | 实测 `uv_timer_t`/`uv_fs_event_t` 回调都处于 fast-event 上下文，直接碰 vim API 会 `E5560`（02 §6） |
| D17 | 订阅者与刷新回调都经 `pcall` 隔离，失败只记日志 | 一个坏掉的 UI 监听器不能打断刷新管线；代价是回调内的断言不传播（测试改为在用例体内断言，05 §3） |
| D18 | `repo_manager` 用**不透明引用令牌** `attach(ref, path, cb)` / `detach(ref)` 做引用计数 | buffer（`buf:3`）、侧边栏、命令各自持引用；同一仓库共享一个 Repo，最后一个引用释放才 `dispose`（02 §4） |
| D19 | **`exec.run` 统一把回调切回主循环**（`vim.schedule`），«回调在主循环» 是本插件的全局契约 | 实测 `vim.system` 的退出回调**本身就在 fast-event 上下文**：那里 `vim.notify`/`nvim_buf_set_lines` 会报 E5560，M3 渲染器与 M4 动作回调会被 pcall 静默吃掉。在一个地方做掉，比让每层自己 schedule 可靠（02 §2/§7）|
| D20 | 元数据监听目标由适配器可选钩子 `metadata_dir(root)` 给出（缺省才回落 `<root>/<keyfile>`） | git worktree/submodule 的 `.git` 是**文件**、真 index 在仓库之外；不解析就永远发现不了 `git add`（02 §3.2） |
| D21 | 路径 map 键在 Windows 上**大小写折叠**（`base.path_key`） | `D:/Repo` 与 `d:/repo` 是同一目录，不折叠就变成两个 Repo（两个缓存 + 两个监听 + 双倍进程） |
| D22 | 引用取消分**三层**：`attach` 进入即递增自己 ref 的世代号（最新者胜）、每个释放路径（`detach`/`_remove`）逐 ref 递增、`dispose_all` 递增**模块级 epoch**（覆盖从未绑定的在飞引用）；回调两者都校验 | 检测是异步的：不递增的话，晚到的回调会把已释放的 ref 重新建仓（监听 + status 进程永久泄漏），或在 `dispose_all` 之后「复活」仓库（02 §7 二轮 major 2） |
| D23 | `relpath` 对「路径 == 根」返回 `''` 而非 nil | 前缀（根 + 分隔符）天然比根长一字符，等值分支不显式处理的话 `active()` 在 cwd 即仓库根时解析不到（02 §7 二轮 major 1） |
| D24 | sign 列排布按**实测**：priority 高的在最左，窄列时保留 priority 高的那个；upstream 位用 `+1000` 偏移（严格大于本地最高优先级 100） | 于是双列读起来就是 `git status --short` 的 XY（index 左、worktree 右），窄列留的是已暂存状态（03 §3.3、§7） |
| D25 | 侧边栏行模型 `kind = header \| entry \| banner`，缓存在 `vim.b[bufnr].vcssign_items`；`item_at/entry_at` 用 **0 基行号**（与 extmark 行号一致） | keymap/actions 只能经这两个 API 取「当前是哪个文件」，UI 层因此完全不碰 VCS 命令；`entry_at` 返回副本，M4 按 `path`/`rel_path` 值比较（03 §4） |
| D26 | keymap 只实现 UI 动作（`q`/`r`/`?`）；其余经 `keymap.dispatch(action, ctx)` 交给 `vcssign.actions`（延迟 `require`，M3 时不存在则明确提示）；能力门在 keymap **先**挡（INFO） | 单一入口让「真实按键」和「`:Vcssign`」走同一条路；UI 层不拼命令行；`open_tab` 复用 `open(entry, { tab = true })`，动作层只有一个入口 |
| D27 | 侧边栏订阅**跟着缓冲区**（buffer 生命周期），不跟窗口 | 窗口隐藏时仓库消失（或 `dispose_all`）也能把窗口+缓冲区一并销毁；`close` 只关窗口、缓冲区复用，重开瞬时且不丢列表 |
| D28 | 动作层（04）是唯一把「用户意图」翻成 VCS 命令的地方：所有动作签名统一为 `fn(target, opts?)`，`target` 可以是侧边栏 `StatusEntry`、路径字符串或 nil（nil 时解析为「侧边栏光标行 → 当前缓冲区文件 → cwd」） | 按键与 `:Vcssign` 共用同一实现；UI 层不拼命令行；一个动作只有一个入口（`open_tab` 就是 `open(entry, {tab=true})`） |
| D29 | 命令层用 `repo_manager.ensure(path, cb)` 解析仓库：按**最近的 marker** 判定，且会用 `cmd:<path>` 引用把仓库钉到会话结束 | 「`:Vcssign` 第一次用就要能用」；嵌套仓库时内层文件不会被判给已 attach 的外层仓库；重复命令不累积引用 |
| D30 | 用户回答（动作结果、命令失败）走 `log.notify`/`log.notify_error`：**不受 `log_level` 门限、不经 `vim.schedule`**；系统级拒绝（`svn: no staging area`）不带 `vcssign:` 前缀 | `log_level` 管的是插件自己的唠叨，不是回答用户按下的那一下；调用点本来就在主循环（D19） |
| D31 | 生命周期去抖用「每缓冲区只 attach 一次」的记忆表，不在 `repo_manager` 里套 100ms 防抖；`VimLeavePre` 只清理、不杀正在跑的命令 | 风暴的本质是同一缓冲区反复进入（`attach` 本身幂等），防抖会连「第一次 attach」一起推迟；命令在退出时是否还在飞，由 `exec` 的超时定时器兜底（04 §7.1） |
| D32 | 侧边栏持有自己的 manager 引用（`sidebar:<system>|<root>`，`repo_manager.hold`），缓冲区在就持有；`ensure` 的引用是「每仓库一个」(`cmd:<root>`) | 侧边栏缓冲区比窗口活得久：没有这条引用，「关掉仓库里最后一个文件」会把用户正在看的列表一起拆掉（M4 审查 major）；每仓库一个引用同时解决「重复命令累积引用」 |
| D33 | 动作条目按**身份**绑定仓库：`abspath(repo.root, entry.rel_path) == entry.path` 才认 | `rel_path` 是渲染它的那个 root 的相对路径；仓库套仓库时「包含该路径的最深仓库」是另一个仓库，会把外层的相对路径交给内层（M4 审查 major） |
| D34 | 只读窥视（`get_status`/`get_entries`）按**最近 marker** 解析、只读缓存、不阻塞；仓库未跟踪时返回 nil/`{}` 并在后台**每路径最多一次**预热，用共享的 `get_status` 引用 | 与命令层的 `ensure` 同一套解析规则（不然嵌套仓库会被父仓库的缓存冒充）；不按路径钉住仓库，避免集成方查过的每个目录都挂一个监听 |
| D35 | 格式/静态检查工具**钉版本**并由 `scripts/tools.sh` 下到 `deps/`（stylua 2.3.1 / luacheck 1.2.0，gitignored，gitsigns 同款布局） | `format-check` 只有在工具版本固定时才可复现；二进制不入库 |
| D36 | 检查的文件集从 `git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua'` 取，`impl/`、`temp/`、`deps/` 排除 | 新加（已 `git add`）的文件不会漏检，计划文档与 fixture 不该被格式化 |
| D37 | `doc/tags` 不入库（`.gitignore`）；手写帮助文件由 `test/doc_spec.lua` 与代码对齐：配置键 / 子命令 / 状态 / 高亮组 / 键位动作 / 公共 API 逐项必须在文档里出现，并额外在 `temp/_spec/` 的副本上跑一次 `:helptags` 验证 tag 唯一 | 没有生成器时（05 §5），文档漂移只能靠断言拦；生成物不入库是 gitsigns 的做法 |

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
