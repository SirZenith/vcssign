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
| D5 | 每仓库一个 `Repo` 对象，状态缓存为 `path → {upstream_status, local_status}`；FS 监听（去抖）只置脏，统一经 `refresh` 防抖管线拉取 | oil-vcs-status 的成熟模式；避免监听回调里直接跑命令造成风暴 |
| D6 | 侧边栏 = 专属 nofile 缓冲区（`vcssign://<root>`）+ 可配置 `right/left/float` 窗口；每行**两个 extmark sign 位**（upstream/local）+ 行文本 | 双状态列与 oil-vcs-status 一致；extmark 比 `:sign` 好清理（一个 namespace `clear` 即可） |
| D7 | 状态枚举以 oil-vcs-status 的 `StatusType` 为基础精简为「核心 + upstream 前缀」两族；svn 特有状态（replaced/missing/switched/external）单列 | 见 01 §2 统一映射表 |
| D8 | 动作按 VCS 能力声明：适配器暴露 `capabilities = { stage=true, diff=true, commit=true … }`，UI/命令按能力启用 | svn 无暂存区；避免 UI 层 if git / if svn 散落 |
| D9 | 按仓库并发刷新用「串行化队列 + 防抖」（gitsigns `throttle_async` 思路的回调简化版），`in_flight` 标志防重入 | 监听风暴 + 手动 refresh 同帧触发时不会并发跑同一 repo 的 status |
| D10 | 测试仓库放 `temp/`（用户提供的位置）；由 `scripts/make_test_repos.sh` 幂等生成 git / svn 两个仓库，fixture 状态可复现 | 本会话沙箱为只读无法创建，脚本化后任何环境可复现（05） |

## 5. 风险与待验证项

1. **svn 在 Windows 的可用性与输出格式** —— `svn info --show-item wc-root` 需 svn ≥ 1.9；需在 05 的 fixture 生成阶段实测确认输出（计划内含验证步骤）。
2. **Linux 上 libuv fs_event 不支持递归** —— 初版策略：仅监听 repo root（非递归）+ `.git` / `.svn` 目录 + 依赖 BufEnter/FocusGained/手动 refresh；不做 oil-vcs-status 的全子目录展开（大仓库代价高）。列为后续优化。
3. **git worktree / submodule** —— D4 的命令式 root 检测已覆盖 worktree；submodule 内部状态初版只显示 submodule 自身的修改状态。
4. **外层仓库与嵌套仓库**（git 仓库里 checkout 了 svn 工作副本）：registry 按当前 buffer 路径逐系统探测，取**路径上最近的 root**；同一会话允许多个不同 VCS 的 Repo 并存。
5. **`.gitignore` 需要追加 `temp/`** —— 属于 `impl/` 之外的改动，本计划会话无权限修改，已在 05 中列为 build 阶段第 0 步（或用户手动）。

## 6. 里程碑与验收总览

| 里程碑 | 计划文件 | 验收 |
|--------|----------|------|
| M1 VCS 抽象层 | 01 | git/svn 适配器在真实 `temp/` 仓库上 status/root 解析全部通过（spec 见 05） |
| M2 仓库运行时 | 02 | Repo 缓存 + 监听置脏 + 防抖刷新，手动改文件后 1s 内（默认去抖 300ms+防抖 200ms）状态变化可观测 |
| M3 侧边栏 UI | 03 | `:Vcssign` 打开/关闭/刷新；双 sign 状态列正确；高亮正确；光标行有文件路径 |
| M4 命令与动作 | 04 | `:Vcssign` 全部子命令工作；git 仓库可 stage/unstage/commit；svn 仓库无 stage 菜单项 |
| M5 测试与工程化 | 05 | `make test` / `make format` 在 Windows 与 CI（Linux）都跑通 |
