# vcssign — 多版本管理工具文件状态侧边栏 · 总体规划（00 / 总览）

> 本文件是 `impl/init/` 计划系列的入口。按实现优先级拆分的计划文件：
>
> | 编号 | 文件 | 内容 | 优先级 |
> |------|------|------|--------|
> | 00 | `00-overview.md` | 目标、参考架构分析、总体架构、关键决策（本文） | — |
> | 01 | `01-vcs-adapter.md` | VCS 抽象层 + git / svn 适配器（root 检测、状态解析） | P0 |
> | 02 | `02-repo-runtime.md` | 进程执行、仓库对象、状态缓存、FS 监听、刷新管线 | P1 |
> | 03 | `03-sidebar-ui.md` | 侧边栏窗口管理、渲染、高亮、按键 | P2 |
> | 04 | `04-commands-actions.md` | 用户命令、动作（stage / diff / commit 等）、autocmd 生命周期 | P3 |
> | 05 | `05-testing-infra.md` | `temp/` 测试仓库、测试脚手架、lint / CI / 文档 | P4（与 01–03 并行推进） |

---

## 1. 目标

做一个 Neovim 插件 **vcssign**：

- 在侧边栏窗口中展示**当前 VCS 仓库的文件状态列表**（未跟踪 / 新增 / 修改 / 删除 / 冲突 / 重命名 等），双状态列（暂存区状态 + 工作区状态）。
- 初版支持 **git 与 svn**；架构上保证新增一种 VCS（hg、jj……）只需新增一个适配器模块。
- 状态自动刷新（文件系统监听 + autocmd + 手动命令兜底）。
- 提供围绕状态列表的常用动作：打开文件、查看 diff、stage/unstage（git）、commit 集成。

非目标（初版明确不做）：

- 行内 hunk 级标记（gitsigns 的核心能力，不在本插件范围内）。
- blame、行内 blame。
- git 之外的 stage/unstage（svn 没有暂存区概念，动作按 VCS 能力声明，见 04）。

## 2. 参考架构分析

### 2.1 gitsigns.nvim（工程质量标杆）

值得借鉴：

| 模块 | 借鉴点 |
|------|--------|
| `gitsigns/config.lua` | schema 化配置：字段表驱动校验 + 默认值深合并 + 未知键报错；help 文档由 schema 生成 |
| `gitsigns/git/cmd.lua` | 命令执行细节：`--no-pager --literal-pathspecs -c core.quotepath=off`、强制 `LC_ALL=C`、Windows 下 `MSYS=noglob` 防止路径被 MSYS2 改写 |
| `gitsigns/debounce.lua` | `debounce_trailing`（自包含、无依赖）；刷新管线的防抖直接移植（MIT，注明出处） |
| `gitsigns/attach.lua` / `cache.lua` | attach/detach 生命周期 + per-key 缓存表 + `on_detach` 清理钩子（本插件 attach 的对象是「仓库」而非「缓冲区」，但生命周期编排方式相同） |
| `gitsigns/cli.lua` | `:Gitsigns` 子命令分发 + 补全的模式（简化后用于 `:Vcssign`） |
| `gitsigns/debug/log.lua` | 分级日志 + `debug_mode`，测试与排障必备 |
| `test/`（nvim-test） | spec 文件组织、helper（`gs_helpers.lua`）、`make test FILTER=...` 工作流 |

避免照搬：

- gitsigns 自研的 coroutine async 框架（`async.lua` ~690 行 Task/Handle 类体系）。vcssign 只需要回调式 + `vim.system`（Neovim ≥ 0.10），复杂度不需要对齐。
- signcolumn 行内渲染那套 manager/hunks 机制（非目标）。

### 2.2 vcs-helper.nvim（多 VCS 抽象的直接参考）

值得借鉴：

- `systems/base.lua` + `meta/systems.lua`：**接口即元类型定义**（`VcsSystem` 的每个方法都有 `@param/@return` 注释），git/svn 各自实现同一接口；`systems/init.lua` 负责「探测活跃系统 + 保存 root」。
- `systems/git.lua` / `systems/svn.lua` 的状态行解析正则（真实输出格式的经验沉淀）。
- `util/run_cmd`：基于 `vim.loop.spawn` 的最小异步进程封装 + `do_async_steps` 串行步骤。

需要修正的问题（规划中已规避）：

- **root 检测用 `.git`/`.svn` 关键字文件向上扫描**（`path_util.find_root_by_keyfile`）。git worktree / submodule 中 `.git` 是**文件**不是目录，该实现会失效 → 见 01 的方案（`git rev-parse --show-toplevel` 优先）。
- `parse_status_line` 里用 `vim.fn.getcwd()` 拼绝对路径 —— 上下文依赖，cwd 变化后即错误 → 状态解析必须以 **repo root 参数**为基准。
- git status 未加 `-z` / `--porcelain`，遇到含空格路径、`core.quotepath` 引号路径会解析错乱 → 见 01。

### 2.3 oil-vcs-status（侧边栏渲染 + FS 监听的直接参考）

值得借鉴：

- `status/systems/vcs_system.lua`：**仓库对象**基类（`root_dir / is_dirty / is_updating / status_tree`）+ **libuv fs_event 监听 + 按路径去抖 + handle/timer 池化复用**；Linux 上 libuv 不支持递归监听时手动展开子目录。
- git / svn 的 `STATUS_MAP`（单字符 → 枚举）与 `constant/status.lua` 的统一状态枚举设计。
- `config.lua` 的 `status_symbol / status_hl_group / status_priority` 三件套：符号、高亮组、sign 列宽度不足时的优先级。
- `status_tree.lua`：树形状态聚合（目录的状态 = 子节点状态的聚合）。

本插件与它的差异：oil-vcs-status 把状态画到 **oil 文件浏览器的 signcolumn** 上；vcssign 是**独立的侧边栏列表窗口**。渲染层完全不同，数据层（状态枚举、监听、树聚合）高度可参考。

## 3. 总体架构

```
┌──────────────────────────────────────────────────────────────┐
│                         plugin/vcssign.vim                    │
│              （命令注册、延迟加载入口，参考 gitsigns）            │
└────────────────────────────────────┬──────────────────────────┘
                                     │ setup()
┌────────────────────────────────────▼──────────────────────────┐
│  config（schema 校验+默认值）   log（分级日志）   status_type    │
└────────────────────────────────────┬──────────────────────────┘
┌────────────────────────────────────▼──────────────────────────┐
│  vcs 层：base 接口 + git / svn 适配器 + registry（探测活跃系统） │  ← 01
│    · find_root / status(args→status_map) / stage / commit …   │
└────────────────────────────────────┬──────────────────────────┘
┌────────────────────────────────────▼──────────────────────────┐
│  repo 层：Repo 对象（一个 root 一个）                            │  ← 02
│    · 状态缓存 status_map: path → {upstream, local}             │
│    · FS 监听（去抖、池化）→ 标脏 → 刷新管线（防抖+串行）          │
│    · 进程执行 exec（vim.system 封装，gitsigns 参数经验）         │
└────────────────────────────────────┬──────────────────────────┘
┌────────────────────────────────────▼──────────────────────────┐
│  UI 层：Sidebar（窗口/缓冲区管理）+ renderer（行/树渲染、extmark）│  ← 03
│    · 两个 sign 位 + 文件名行文本 + 分组标题                       │
│    · 高亮组 VcssignModified …（默认链接 Diff* / Diagnostic*）    │
└────────────────────────────────────┬──────────────────────────┘
┌────────────────────────────────────▼──────────────────────────┐
│  命令与动作：:Vcssign [toggle|open|refresh|stage|…]             │  ← 04
│    · autocmd 生命周期（BufEnter/DirChanged/退出清理）            │
│    · 动作按 VCS 能力声明（git: stage/unstage；svn: 只读 + commit）│
└────────────────────────────────────────────────────────────────┘
```

### 目标目录结构

```
vcssign/
├── plugin/vcssign.vim          # 命令注册（`:Vcssign`），lazy 入口
├── lua/vcssign/
│   ├── init.lua                # setup() 与公共 API
│   ├── config.lua              # schema 化配置
│   ├── status_type.lua         # 统一状态枚举 + 符号/高亮/优先级默认值
│   ├── exec.lua                # vim.system 封装（gitsigns git/cmd.lua 的参数经验）
│   ├── debounce.lua            # 移植 gitsigns/debounce.lua（MIT 注明）
│   ├── log.lua                 # 分级日志
│   ├── vcs/
│   │   ├── init.lua            # registry：系统注册表 + 活跃系统探测
│   │   ├── base.lua            # VcsSystem 接口（含 emmylua 元类型定义）
│   │   ├── git.lua             # git 适配器
│   │   └── svn.lua             # svn 适配器
│   ├── repo.lua                # Repo 对象：缓存 + 监听 + 刷新管线
│   ├── repo_manager.lua        # root → Repo 映射，attach/detach 生命周期
│   ├── sidebar/
│   │   ├── init.lua            # 窗口/缓冲区管理（open/close/toggle）
│   │   ├── renderer.lua        # 行文本 + extmark sign 渲染
│   │   └── keymap.lua          # 窗口内按键
│   ├── actions.lua             # stage/unstage/diff/commit/open（按能力分派）
│   ├── autocmds.lua            # 生命周期 autocmd
│   └── cli.lua                 # :Vcssign 子命令分发 + 补全
├── temp/                       # 测试仓库（gitignore，见 05；本会话沙箱只读未能创建）
├── scripts/
│   ├── make_test_repos.sh      # 生成 temp/ 下 git/svn 测试仓库（05）
│   ├── run_tests.sh            # headless nvim 跑 test/（05）
│   └── gen_help.lua            # （后期）从 config schema 生成 help，参考 gitsigns
├── test/
│   ├── preload.lua             # 测试入口 require 链（参考 gitsigns test/preload.lua）
│   ├── helpers.lua             # 断言/等待异步收敛的工具（参考 gs_helpers.lua）
│   ├── vcs_git_spec.lua
│   ├── vcs_svn_spec.lua
│   ├── repo_spec.lua
│   ├── renderer_spec.lua
│   └── sidebar_spec.lua
├── doc/vcssign.txt             # 手册（后期由 schema 生成）
├── stylua.toml / .luacheckrc   # 与 gitsigns 同款工具链
└── Makefile                    # make test / format / doc-check
```

## 4. 关键决策（ADR 摘要）

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

## 5. 风险与待验证项

1. **svn 在 Windows 的可用性与输出格式** —— `svn info --show-item wc-root` 需 svn ≥ 1.9；需在 05 的 fixture 生成阶段实测确认输出（计划内含验证步骤）。
2. **Linux 上 libuv fs_event 不支持递归** —— 初版策略：仅监听 repo root（非递归）+ `.git` / `.svn` 目录 + 依赖 BufEnter/FocusGained/手动 refresh；不做 oil-vcs-status 的全子目录展开（大仓库代价高）。列为后续优化。
3. **git worktree / submodule** —— D4 的命令式 root 检测已覆盖 worktree；submodule 内部状态初版只显示 submodule 自身的修改状态。
4. **外层仓库与嵌套仓库**（git 仓库里 checkout 了 svn 工作副本）：registry 按当前 buffer 路径逐系统探测，取**路径上最近的 root**；同一会话允许多个不同 VCS 的 Repo 并存。
5. **`.gitignore` 需要追加 `temp/`** —— 属于 `impl/` 之外的改动，本计划会话无权限修改，已在 05 中列为 build 阶段第 0 步（或用户手动）。

## 6. 里程碑与验收总览

| 里程碑 | 计划文件 | 验收 |
|--------|----------|------|
| M1 VCS 抽象层 | 01 | ✅ 完成（53/53）：git/svn 适配器在真实 `temp/` 仓库上 status/root 解析全部通过（spec 见 05） |
| M2 仓库运行时 | 02 | ✅ 完成（81/81）：Repo 缓存 + 监听置脏 + 防抖刷新，手动改文件后 1s 内状态变化可观测 |
| M3 侧边栏 UI | 03 | ✅ 完成（107/107）：窗口/缓冲区生命周期 + 双 sign 状态列（屏幕单元格断言）+ 高亮 + 按键；`:Vcssign` 命令族仍属 M4 |
| M4 命令与动作 | 04 | ✅ 完成（167/167，含审查修复）：`:Vcssign` 全部子命令（含 `diff`/`debug`）+ 真实按键与命令同一条路；git stage/unstage/commit 都用 VCS 自身核对过，svn 无 stage 且 commit + `svn log` 可查；生命周期 autocmd 与 `VimLeavePre` 清理有句柄级断言（04 §6/§7） |
| M5 测试与工程化 | 05 | ✅ 完成（174/174）：`stylua.toml` / `.luacheckrc` / `Makefile`（help/tools/fixtures/test/format/format-check/lint）+ 钉版本的 `scripts/tools.sh`；`make format-check` 零输出、`make lint` 0 警告、`make test` 174/174；`doc/vcssign.txt`（8 节）由 `doc_spec` 7 用例逐项守着（05 §4–§6）。CI workflow 仍是 backlog（本机无远端可验证） |
| M6 行级 sign（转向，在制品） | 07 | 🚧 **进行中（Step 1–8/14）**：用户要求把侧边栏换成 gitsigns 式**行级 sign**；侧边栏与 `status_type` 已退役，适配器换成 `show`/`is_tracked`/`blame`/`apply_patch`/`revert`，`hunk` / `diff` / `signs` / `attach` 已落地，autocmd 触发与逐缓冲开关已接通，`nav` / `keymap` 也接上了（`]c`/`[c` 可跳，其余键位等 Step 9–11）。HEAD `f54b6af`，`make test` **202/202**、`make format-check` 零输出、`make lint` 0/0（38 文件）。**剩余 Step 9–14 与交接说明见 07 §6.1–§6.4** |
