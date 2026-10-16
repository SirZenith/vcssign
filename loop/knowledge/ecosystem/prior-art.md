# 生态先例：gitsigns / vcs-helper / oil-vcs-status

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md` §2 与
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §9。原文抽取，未做改写。

**要点**：gitsigns.nvim 是工程质量标杆，也决定了本插件的默认键位、默认值与 hunk 类型命名；
vcs-helper.nvim 是多 VCS 抽象的直接参考；oil-vcs-status 是 FS 监听 + 渲染的直接参考。
我们**只借结构、默认值与措辞，不借 async 框架**（D46），并刻意不做 `:Gitsigns` 那类命令族。
本插件的 `lua/vcssign/` 对应关系：`vcs/` ↔ 抽象层、`repo.lua`+`debounce.lua` ↔ 监听与刷新、
`signs.lua`+`hunk.lua`+`diff.lua` ↔ 行级 sign。

---

*来源：`loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md`，原文 `## 2. 参考架构分析`*（标题层级已下移一级）

### 2. 参考架构分析

#### 2.1 gitsigns.nvim（工程质量标杆）

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

#### 2.2 vcs-helper.nvim（多 VCS 抽象的直接参考）

值得借鉴：

- `systems/base.lua` + `meta/systems.lua`：**接口即元类型定义**（`VcsSystem` 的每个方法都有 `@param/@return` 注释），git/svn 各自实现同一接口；`systems/init.lua` 负责「探测活跃系统 + 保存 root」。
- `systems/git.lua` / `systems/svn.lua` 的状态行解析正则（真实输出格式的经验沉淀）。
- `util/run_cmd`：基于 `vim.loop.spawn` 的最小异步进程封装 + `do_async_steps` 串行步骤。

需要修正的问题（规划中已规避）：

- **root 检测用 `.git`/`.svn` 关键字文件向上扫描**（`path_util.find_root_by_keyfile`）。git worktree / submodule 中 `.git` 是**文件**不是目录，该实现会失效 → 见 01 的方案（`git rev-parse --show-toplevel` 优先）。
- `parse_status_line` 里用 `vim.fn.getcwd()` 拼绝对路径 —— 上下文依赖，cwd 变化后即错误 → 状态解析必须以 **repo root 参数**为基准。
- git status 未加 `-z` / `--porcelain`，遇到含空格路径、`core.quotepath` 引号路径会解析错乱 → 见 01。

#### 2.3 oil-vcs-status（侧边栏渲染 + FS 监听的直接参考）

值得借鉴：

- `status/systems/vcs_system.lua`：**仓库对象**基类（`root_dir / is_dirty / is_updating / status_tree`）+ **libuv fs_event 监听 + 按路径去抖 + handle/timer 池化复用**；Linux 上 libuv 不支持递归监听时手动展开子目录。
- git / svn 的 `STATUS_MAP`（单字符 → 枚举）与 `constant/status.lua` 的统一状态枚举设计。
- `config.lua` 的 `status_symbol / status_hl_group / status_priority` 三件套：符号、高亮组、sign 列宽度不足时的优先级。
- `status_tree.lua`：树形状态聚合（目录的状态 = 子节点状态的聚合）。

本插件与它的差异：oil-vcs-status 把状态画到 **oil 文件浏览器的 signcolumn** 上；vcssign 是**独立的侧边栏列表窗口**。渲染层完全不同，数据层（状态枚举、监听、树聚合）高度可参考。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `## §9 与 gitsigns 的有意差异`*（标题层级已下移一级）

### §9 与 gitsigns 的有意差异

| 差异 | 说明 |
|---|---|
| **不引入 async 框架** | 沿用回调链 + 错误优先 `cb(err, ...)`（D46），不用 coroutine/plenary 那套 |
| **用内置 diff，而非每缓冲区起外部进程** | `vim.text.diff`（D39）；svn 没有 `git diff` 本地后端，内部 diff 让 git/svn 同路 |
| **不做 `:Gitsigns` 那类命令族** | 只保留 `:Vcssign` 的子命令集（`setqflist`、`toggle_deleted`、`select_hunk`、导航子命令族等列入 backlog，等用户点名） |
| **svn 无暂存区 → 只有一层 sign** | `VcsCaps.staged_signs` 门控；git 才有 HEAD↔index↔worktree 双命名空间 |
| **reset 类动作不做内存内 patch 应用** | 有未保存改动时直接拒绝（D45），而不是像 gitsigns 那样同步改缓冲区文本 |
