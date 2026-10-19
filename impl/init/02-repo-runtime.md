# 02 · 仓库运行时：进程执行、Repo 对象、缓存、FS 监听、刷新管线（P1）

> 承接 01 的数据通路，把它变成「活」的：元数据变更自动发现、
> 并发收敛到一条防抖刷新管线、仓库存活探测。本层完成后，UI 层只管消费事件。
>
> **状态：✅ 已完成**（M2）；**M6 Step 2 起降级为「仓库会话」**（D38）：不再缓存/查询文件状态，
> 只负责元数据监听 + 存活探测 + 事件广播。验收 02 §5.1–5.5 的**等效用例**见 §5（M6 版）。
> 与初版计划的偏差见 §6（全部为实测驱动）。

## 1. 交付物

| 文件 | 职责 | 状态 |
|------|------|------|
| `lua/vcssign/exec.lua` | `vim.system` 封装：参数经验（gitsigns `git/cmd.lua`）+ 统一错误结构 + `stdin`（M6 Step 2） | ✅ M1 提前落地 |
| `lua/vcssign/config.lua` | 加 `watch` / `update_debounce_ms` / `retry_delay_ms` / `retry_max_ms` / `log_level` | ✅ |
| `lua/vcssign/log.lua` | 分级日志：debug/info/warn/error，全部经 `vim.schedule` → `vim.notify` | ✅ 新增 |
| `lua/vcssign/util.lua` | `is_dir` / `subscribe` / `emit`（隔离监听器异常） | ✅ 新增 |
| `lua/vcssign/debounce.lua` | 移植 gitsigns `debounce_trailing`（MIT 注明）+ `cancel` 返回值（见 §3.3） | ✅ |
| `lua/vcssign/repo.lua` | `Repo` 对象：元数据监听（句柄池化）+ 存活探测 + 刷新管线 + 退避重试 + `dispose`（**无状态缓存**，D38） | ✅ |
| `lua/vcssign/repo_manager.lua` | `root → Repo` 映射、attach/detach 引用计数、全局事件分发 | ✅ |

## 2. exec.lua（进程执行封装）

```lua
---@param cmd string[]            # {"git", "status", ...} 拼好的参数表
---@param opts { cwd: string, env?: table<string,string>, timeout?: integer }
---@param cb fun(err: string?, res: vcssign.ExecResult?)
M.run(cmd, opts, cb)
```

要点（来自 gitsigns `git/cmd.lua` 的实战经验，去 git 专用化）：

1. 基于 `vim.system(cmd, { cwd=..., text=true, env={LC_ALL="C", ...} }, cb)`。
2. Windows：`env.MSYS = "noglob"`、`env.CYGWIN = "noglob"`（防 MSYS2 展开路径参数）。
3. 超时（默认 `config.exec_timeout_ms = 15000`）via `SystemObj:kill()` + timer。
4. 返回统一结构；`code > 0` 时 `err = "exit <code>: <stderr 首行>"`，方便上层统一告警（`M.error_message`）。
5. `M.split_nul(stdout)`（git `-z` 输出用）与 `M.split_lines(stdout)`（去结尾空行；逐行去 `\r`）。
6. **不做** gitsigns 的 coroutine async 框架 —— 本插件所有调用点都是回调链。
7. `pcall` 包住 `vim.system`：命令不存在时它**抛异常**（ENOENT）而非回调（已实测）。
8. **回调一律切回主循环**（M2 审查后新增）：`vim.system` 的退出回调实测就在 fast-event 上下文
   （`vim.in_fast_event() == true`）。在那里 `vim.fn.fnamemodify`/`vim.fs.normalize`/`vim.uv.*`/
   `vim.schedule` 可用，但 **`vim.notify` 与 `nvim_buf_set_lines` 会报 E5560**。
   若不在 `finish` 里统一 `vim.schedule` 一次，M3 的渲染器与 M4 的动作回调就会静默失效（被 pcall 吃掉）。

## 3. Repo 对象（repo.lua）

一个仓库 root 一个实例，类型即模块表（`M.__index = M`）。

```lua
---@class vcssign.Repo
---@field system vcssign.VcsSystem
---@field root string
---@field marker_path string                    # root/.git 或 root/.svn
---@field metadata_path string                 # 实际监听的元数据目录（见 §3.2）
---@field refs table<string, true>              # 持有它的引用令牌
---@field is_dirty boolean                      # 有变更待刷新
---@field is_updating boolean                   # 探测中（防重入）
---@field has_pending boolean                   # 探测期间又来了一次请求 → 跑完补跑
---@field is_deleted boolean                    # 仓库消失 / 已 dispose
---@field has_loaded boolean                    # 至少成功探测过一次（存活检查），
--                                              # 或 root 由 `verified` 直接交进来（M7-3）
---@field error_count integer                   # 连续失败次数（退避指数）
---@field last_error string?
---@field fs_handles table<string, uv.uv_fs_event_t>   # 监听路径 → 句柄
---@field fs_handle_pool uv.uv_fs_event_t[]            # 句柄池（复用）
M.new(system, root) → Repo
```

> ⚠ **M6 Step 2（D38）**：`status` / `status_map` 两个字段与 `entries()` / `get_entry()` /
> `get_status()` 三个方法已删除 —— Repo 不再缓存或查询任何文件状态。需要状态的调用方
> （`actions.lua`、`:Vcssign debug`）自己按需即时跑一把 `system.status`。

> ⚠ 与初版计划的两处差异：**没有** `fs_timers` / `fs_timer_pool`
> （去抖只做一层，见 §3.3）；字段用 `root` 而非 `root_dir`（与 01 的适配器术语一致）。

### 3.1 状态 API（回调链，供 UI 消费）

```lua
Repo:refresh(cb?)      # 走防抖窗口；cb(err) 在本轮结束时调用一次
Repo:refresh_now(cb?)  # 跳过防抖（动作后强制刷新、`verified` 之外的首次绑定）；并重置退避计数
Repo:mark_dirty()      # 只置脏 + 排队（FS 事件/autocmd 用）
Repo:status(cb)        # 仓库级状态视图（M7 步骤 4）：cb(err, entries, trusted)
Repo:has_status()      # 适配器是否提供 status 钩子（否则调用方走逐文件提问）
Repo:on_update(fn)     # 一次存活探测成功 → fn(repo, changed)；返回 unsubscribe（M7 步骤 2）
Repo:on_error(fn)      # 一次存活探测失败（超时/权限/EBUSY…）→ fn(err, repo)
Repo:on_delete(fn)     # 明确否定（marker 消失 / 适配器判定「不是仓库」）→ fn(repo)
Repo:dispose()         # 停监听/定时器/订阅，终态
Repo:start()           # 开始监听（manager 建仓时调用）
```

> ⚠ **M7 步骤 2（08 P0-3）**：`on_update` 的第二个参数 `changed` 是三态——
> **集合**（`table<string, true>`，归一化绝对路径）= 这一轮 fs 事件指名的文件；
> **`nil`** = 有事但指认不了（`.git/index` / `.svn/wc.db` 变了、目录汇总事件、路径已消失）；
> **空集** = 什么也没动（`FocusGained` / 手动刷新这类「再看一眼」的探测）。
> 只有 fs 事件会记账（`_record_change`）；`mark_dirty` / `refresh*` 是请求，不是证据。
> 订阅方用 `not changed or changed[path]` 判自己要不要动。

> ⚠ **M6 Step 2（D38）**：`refresh*` 的回调现在只收到 `err`（不再有 `entries`）。
> `entries()` / `get_entry()` / `get_status()` 已删除：状态查询改成调用方即时跑一次 `system.status`
> （`actions.fetch_status`；测试用 `helpers.status_entries`）。
>
> ⚠ `refresh*` 的回调由 `pcall` 隔离（见 §3.3），
> 因此**回调里不要写断言**：测试要记录结果、在用例体内断言（spec 里已按此写）。

> ⚠ **M7 步骤 4（08 P0-1）— `Repo:status(cb)` 的三态与「证据」**：
> 一次 `system.status` 全仓查询，`cb(err, entries, trusted)`。`entries[abs_path]` 是
> `vcssign.FileStatus`；**路径缺席 = 被跟踪且与基线同步**（干净文件因此一个基线命令都不用发）。
> 第三个参数 `trusted` 回答的不是「新鲜吗」，而是「**别的程序会不会已经改了它没告诉我**」：
> `trusted = 查询前后 baseline_stamp 相同`。不可信时调用方**不能**把 `staged = false` 当结论
> （照旧读一次 `show HEAD`，多 1 个进程但不会出错的标志）。
> - **失效是事件驱动的、零 TTL**：工作区事件把已知 tracked 条目的 `worktree` 置真（一次保存
>   因此 0 进程），其余一律退缓存；metadata 事件（`.git/index`、`.svn/wc.db`）退全缓存。
> - **查询期间存储自己动了**（`baseline_stamp` 变了）就**不缓存、不重查**，只投递这一次答案：
>   重查会被「查询本身扰动了存储」喂成一个循环。
> - 并发调用方由 `_status_waiters` 合并：二十个 buffer 同时 attach 只花一次查询。
> - `attach` 侧还有一条语义（在 `attach.lua`）：当视图说文件干净时，**基线取 buffer 自己的
>   文本**而不是读磁盘——磁盘可能已被外部改写而事件还没到，读它会把别人的编辑变成幻影 hunk。

### 3.2 FS 监听（自动发现变更）

监听集（`_init_watch`，M6 Step 2 + `f1d1735` 修正后共两项）：

| 路径 | 递归 | 为什么 |
|------|------|--------|
| `metadata_path` | 是（非 Linux） | index / wc 元数据变化 —— 一个 store 服务全仓，所以「指认不了文件」 |
| `root` | **否** | 存活探测（libuv 不报告「被监听目录自身消失」）；**M7 起另兼「哪个文件变了」**——非递归所以 libuv 会给 `filename` |

> ⚠ **M6 Step 2（D38）**：`root` 的直接子目录**不再监听**（工作树内容变化由缓冲区侧的
> `on_lines` 防抖 + 按需 diff 覆盖，见 07 §3.2），旧的 `_sync_watch_set` 随之删除。
>
> ⚠ **但 `root` 自身的非递归监听必须留着**（`f1d1735` 修）：libuv **从不报告「被监听目录
> 自身消失」** —— 实测把 `.git` 改名走，挂在 `.git` 上的 handler 收 **0 个事件**，而挂在
> `root` 上的非递归 handler 立刻收到 `.git` / `.git-gone` 的 rename（3 events）。少了它，
> 工作副本被删后 `Repo` 永不自杀，只能等某次无关 refresh 失败才被回收
> （`repo_spec` 的「`.git` 消失」「`.svn` 消失」两个用例在 `3ecbdd7`..`7acc713` 上因此
> 过滤运行必红、全量运行间歇红）。`_on_fs_event` 已有的「marker 不存在 ⇒ `_mark_deleted()`」
> 分支就是这条探测的落点。

> **实际监听的是 `metadata_path`**，不一定是 `<root>/<keyfile>`：git worktree / submodule 的
> `.git` 是**文件**，真正的 index 在 `<main>/.git/worktrees/<name>/index`（在仓库之外）。
> 由适配器的可选钩子 `system.metadata_dir(root)`（01 §3）解析，缺省回落到 `root/keyfile`。
> 没有这个解析，`git add` 在 worktree 里就永远发现不了（有个专门用例钉住）。

- libuv 在 Linux 上不支持递归 fs_event（inotify 无此模式），那里 `.git` 退化为非递归；
  `.git/index` 是 `.git` 的**直接子项**，所以关键的暂存域信号仍然能拿到（已实测）。
- `_sync_watch_set`（**M6 Step 2 已删除**）：root 层出现新目录 → 补监听；被监听目录消失 → 释放句柄。
  现在监听集固定为 `metadata_path` 一项，不再随目录增删变化。
- 回调里**只做三件事**：记下「这一轮谁动了」（`_record_change`）+ `is_dirty = true` + 重置去抖 timer。
  绝不直接跑命令。记账的三态语义见 §3.1 的 ⚠。
- 监听目录消失 → `_mark_deleted()`（`is_deleted`、停监听、通知 manager detach）。
  `.git` 可能是**文件**（worktree），所以判据是「marker 不存在」而不是「不是目录」。
- 句柄报错（目录被删/不可访问）→ **warn 日志 + 释放该句柄**（不是只记 debug 后留着一个死句柄）；
  目录再出现时由 `_sync_watch_set` 重新拾起。
- `.git` 的 rename 事件 = 仓库被删 → 同上。

**实测（Windows 11 + nvim 0.12.4）：**

| 现象 | 结论 |
|------|------|
| 单个文件内容修改 | root 监听收到 `change=true, filename=base.txt`（非递归也够）✅ |
| `git add` | `.git` 递归监听收到 `index.lock` → `index` 的 rename 序列（约 12 个事件）→ **必须去抖** |
| timer / fs_event 回调 | `vim.in_fast_event() == true` → 一切 vim API 必须先 `vim.schedule`（本文件所有 uv 回调都 `schedule_wrap`） |
| 删除/改名**被监听目录** | 之后 libuv 会**持续投递**事件（探针里刷了上千条，nvim 一度不退出）→ 首个事件里必须 `stop()+close()`；实测 `stop()` 能立即止住风暴 |
| Windows 上重命名被监听目录 | `uv.fs_rename` 成功（句柄是共享删除的）→ §5.4 用例可以这么做 |

### 3.3 刷新管线（防抖 + 串行化）

```
FS 事件 / autocmd / 手动 refresh
        │
        ▼
 mark_dirty() → is_dirty = true → debounce_trailing(update_debounce_ms=200)
        │                              （vimschedule 后调用）
        ▼
 _do_refresh()
   ├─ is_updating → has_pending = true，返回（跑完立即补跑 → 收敛）
   ├─ is_updating = true  ← **先置位，再发命令**
   ├─ system.get_root_async(root, cb)          ← 存活探测（D38，不再跑 status）
   │     成功（拿到 root）→ is_dirty=false → error_count=0 → 清退避
   │                        → has_loaded=true → 取走本轮记账的变更集（_take_changes）
   │                        → emit(on_update, changed)   ← 集合 / nil / 空集，见 §3.1
   │     明确否定（registry.is_definitive_negative）→ _mark_deleted()（不再重试）
   │     其它失败 → 保留 has_loaded → error_count++ → 同一失败串只 warn 一次
   │                → 指数退避重试（1000 × 2^(n-1)，封顶 30000，成功后取消）
   └─ flush waiters → has_pending ? 再跑一轮 : 结束
```

- 「防重入 + 补跑」= gitsigns `throttle_async(schedule=true)` 语义，用回调实现（D9）。
- **先置 `is_updating` 再调命令**：`system.status` 通常是异步的，但能力不支持 / 参数校验失败是
  **同步**回调，先调后置会被同步回调清掉标志，然后真正的异步回调再跑一轮 → 并发刷新。
- **剪裁**（M6 Step 2 起不再适用）：Repo 已无状态缓存；`_on_alive` 一律广播 `on_update`。
  「变化了才通知」的语义（如果有）归渲染层。
- **M7 步骤 2 修正了上一条的代价**：广播依旧每轮都发（它同时是「仓库还活着」的信号），
  但带上了「哪个文件动了」。于是「没变」也能被表达（空集）——这正是 08 §2.5 里
  `FocusGained` 40 → 20 次渲染进入的来源。`_take_changes` 是取走即清（快照原子），
  期间新到的事件算下一轮。
- ⚠ **偏差（去抖只做一层）**：初版计划在 FS 事件上再套一层「按路径的去抖 timer 池」
  （oil-vcs-status 模式），管线本身又有 300ms 防抖 → 600ms 串联延迟且两套定时器。
  实际只保留管线这一层：FS 回调直接 `mark_dirty()`，去抖由 `debounce_trailing` 完成。
  句柄池化保留给 `fs_event`（`fs_handle_pool`）。
- `--no-optional-locks`（01 §4.1 的全局参数）**实测阻止了 `git status` 回写 `.git/index`**
  （mtime 不变），所以不存在「自激刷新环」。仍保留「更新期间忽略 marker 事件」作为保险。
- **回调查错**：waiters 与订阅者都经 `pcall` 调用（`_call_waiter` / `util.emit`），
  坏掉的 UI 监听器不能打断管线；失败会以 `log.error` 浮出（`vim.notify`）。
  代价：回调里的异常不会传播到调用栈 —— 测试不要在回调里断言。
- **`system.status` 本身也 pcall**（M2 审查后新增）：适配器若**抛异常**而不回调，
  `is_updating` 会永远置位、管线彻底塔住。`_do_refresh` 用一个 `done` 闸（幂等）包住
  整个完成路径，同步回调 + 随后抛异常的场景也只算一次。
- **仓库在命令飞行中被 dispose**：完成回调先查 `is_deleted`，直接返回 —— 否则会在已终结的
  对象上 `uv.new_timer()`（破坏 §5.4 的「句柄为零」不变量）。
- **剪裁用 `status_map` 对比而不是数组**（M6 Step 2 起删除）：随缓存一起移除。
- **路径键在 Windows 上大小写折叠**（`base.path_key`）：`_by_root` / `_by_ref`
  的键统一折叠，否则 `D:/Repo` 与 `d:/repo` 会被当成两个仓库（两个监听 + 两个引用计数）。
  （`status_map` 已随缓存删除。）

## 4. repo_manager.lua（生命周期编排）

```lua
M.attach(ref, path, cb)   # ref 是不透明令牌（"buf:3" / "cmd"）
                          # → detect(01) → 找/建 Repo → start 监听 → 首刷 → cb(err, repo)
M.detach(ref)             # 释放一个引用；最后一个引用才 dispose
M.dispose_all()           # VimLeavePre：全部释放，句柄清零
M.get(root) / M.get_by_path(path) / M.active()
M.all() / M.count() / M.ref_count(root)
M.on_repo_attached(fn) / M.on_repo_detached(fn)
```

- 同一 root 只有一个 `Repo`，多个 buffer 共享缓存与监听（引用计数）。
- **M7 步骤 3（08 P0-5）**：`Repo.new(system, root, { verified = true })`——`root` 是
  `detect_async` 刚问过该系统命令拿到的，所以新仓库直接 `has_loaded = true` / `is_dirty = false`，
  首刷不再白跑一次存活探测（每仓库省 1 进程 + 1 轮串行往返，首标 git −40 ms）。
  仓库在 detect 与 `start()` 之间消失的极窄窗口由 watcher 兜住，之后的任何真实触发照旧探测。
- **快速路径**：`registry.detect`（纯 marker 扫描，不起进程）命中已知 root → 直接复用；
  且若该 repo `has_loaded and not is_dirty` → 直接回缓存、**不起进程**（M7 步骤 3 之后，
  **新仓库的第一次** attach 也走这条：`verified` 让 `has_loaded` 一出生就是真）。
  注意这条路径下 `cb` 是**同步**调用的（已在文档注释里写明）。
- `ref` 换仓库（buffer 换目录）→ 先解绑旧的再绑新的，不会泄漏引用。
- 仓库消失（§3.2）→ `repo:on_delete` → manager 移除 + `dispose()` + 广播 detached。
- 所有清理路径都汇到 `Repo:dispose()`：停 fs_event 句柄、关去抖/退避 timer、清订阅与 waiters。

## 5. 验收标准（M6 Step 2 版，见 `test/repo_spec.lua`，20 用例；M7 步骤 2 后 24、步骤 4 后 30）
| # | 场景 | 用例 |
|---|------|------|
| 5.1 | 元数据事件到达订阅者**恰好一次** | 「a metadata change is announced exactly once」（`git add` 后 `on_update` 增量 == 1） |
| 5.2 | 事件风暴 / 同窗口多次请求 → **只探测一轮** | 「a burst of changes collapses into a single probe」「refresh requests inside one window share a single probe」「a manual refresh inside the debounce window is not run twice」 |
| 5.3 | `git add` → `.git/index` 变化 → 广播（linked worktree 也走 gitdir） | 「staging inside a linked worktree is watched through the gitdir target」 |
| 5.4 | 删/移 `.svn`（及 `.git`）→ dispose，句柄与 timer 归零 | 「a vanished .git disposes the repository and frees every handle」「deleting an svn working copy cancels its watcher too」（`helpers.uv_count` 前后相等） |
| 5.5 | 探测失败 → 不回退已加载状态 + 只 warn 一次 + 指数退避，重试自动恢复，不抛异常 | 「a failing probe warns once, backs off, and the retry recovers」+「the backoff retry recovers without any user input」（后者是套件唯一 stderr 行的来源） |
| 5.5b | 明确否定（「不是仓库」）→ 直接 `on_delete`，不重试 | 「a definitive negative deletes the repository instead of retrying」 |
| §4 | 引用计数：第二个引用复用同一对象且不起进程；最后一个释放才 dispose | 「references share one repo and the last release disposes it」 |
| §4 | `dispose_all()` 后无残留句柄 | 「dispose_all leaves nothing behind」 |
| §4 | `active()` 按当前 buffer 解析 | 「active() resolves the repository of the current buffer」 |
| 附加 | 排队中的 `refresh(cb)` 不因仓库消失而挂起；dispose 后 `refresh`/`refresh_now` 立即报错 | 「a queued refresh callback is released when the repository goes away」 |
| 附加 | attach 与 detach 竞态不泄漏引用（检测是异步的） | 「a detach that races an in-flight attach does not leak a reference」 |
| 附加 | 探测飞行中被 dispose，晚到结果不产生任何副作用 | 「a probe that reports after dispose changes nothing」（stub 适配器 + `vim.defer_fn`，完全确定性） |
| 附加 | **linked worktree** 的元数据解析（`.git` 是文件，index 在仓库外） | 「staging inside a linked worktree is watched through the gitdir target」 |
| 附加 | Windows 路径大小写不敏感 | 「path lookups are case-insensitive on Windows」 |
| 附加（二轮） | 仓库根目录本身解析回该仓库（`cd repo && nvim` 时 `active()`） | 「the repository root itself maps back to the repository」 |
| 附加（二轮） | `dispose_all` 之后不再诞生仓库（检测在飞时会话退出） | 「dispose_all cancels an attach that is still detecting」 |
| 附加（二轮） | 防抖窗口内的手动刷新不跑两遍 | 「a manual refresh inside the debounce window is not run twice」 |
| 附加 | 首刷（attach）成功后 `has_loaded`/`is_dirty`/`error_count` 正确 | 「a root the detector resolved costs no second probe (M7 P0-5)」（`count_probes` == 1） |
| 5.7（M7-3） | 交给 `Repo` 的 root 不再探测一次；但之后的显式刷新照旧探测（git 与 svn 各一份） | 「a later trigger still probes a repository that skipped its first one」「a working copy is resolved once too, not once per layer」 |
| 附加 | `on_error` 订阅真会被调用 | 失败用例里 `eq(errors, 1)`, `eq(errors, 2)` |
| 5.8（M7-4a） | 状态视图：一次查询服务全仓且被缓存 / 工作区事件打补丁 / metadata 事件退缓存 / 存储动过之后仍能看到 staged | 「one status query answers the whole repository, and it is cached」「a worktree event is folded into the cached view instead of retiring it」「a metadata change retires the view, because it can move everything」「a view taken before the store moved is never believed about staging」 |
| 5.6（M7-2） | 变更通道三态：工作区事件指认文件 / 元数据事件不指认 / 无事件背后的探测给空集，git 与 svn 各一份 | 「a work tree event announces the file it touched」「a metadata change announces no path, because it moves every baseline」「a probe with no filesystem event behind it announces an empty set」「an svn metadata change announces no path either」 |

## 6. 实测与偏差记录（回写）

0. **M6 Step 2（D38）· Repo 降级为「仓库会话」**：删除 `status`/`status_map`/`entries()`/
   `get_entry()`/`get_status()`/`_apply_status()`，以及 `_do_refresh` 里的 `system.status(...)`；
   刷新改成**存活探测** `system.get_root_async(root, cb)`（复用适配器既有接口，不新增 API）：
   拿到 root ⇒ 存活 ⇒ 广播 `on_update`；`registry.is_definitive_negative(err)` ⇒ `_mark_deleted()`；
   其它错误 ⇒ 退避重试。监听集只剩 `metadata_path`（root 与直接子目录、`_sync_watch_set` 一并删除）。
   连带改动（调用方即时查询）：`actions.resolve` 不再 `get_entry`，改用 `actions.fetch_status`（`t.status` 可用则同步，否则即时 `system.status`）；
   `cli.debug_report` 去掉 `entries=%d`。`exec.run` 增加 `stdin`（字符串原样写入、不补尾换行；`string[]` 逐元素补 `\n`；`text=true` 只解码 stdout）。
   实测（探针 A/B4）：零上下文补丁必须以 `\n` 结尾，否则 `git apply --cached --unidiff-zero` 报 `error: corrupt patch at <stdin>:5`。

1. **去抖只做一层**（§3.3）：去掉「FS 路径 timer 池」，管线防抖兼任。
2. **监听集为 root + 直接子目录 + marker**（§3.2）：初版只写 root + marker，
   那样子目录里的编辑完全不可见；全量递归展开仍是后续优化项。
3. **`entries()` 不排序**（§3.1）：排序/分组归 03。
4. **`fs_timers` / `fs_timer_pool` 字段不存在**：随第 1 条一起取消。
5. **`debounce.lua` 相对 gitsigns 的两处改动**：
   (a) 额外返回 `cancel()` —— `dispose` 必须做到句柄清零，而 gitsigns 的 timer 藏在闭包里够不着；
   (b) 触发时 `vim.schedule` —— luv 回调是 fast-event 上下文，直接调 `fn` 会禁掉 `vim.system` 与全部 vim API。
   同时把「已触发但未调度」的句柄留在池中复用（否则会把下一次调用刚重启的 timer 关掉）。
6. **低级陷阱**：`Repo.new` 里忘了 `M.__index = M` 会让所有方法变 nil（首次跑 spec 时 13 个用例全挂）——
   已加注释固定。
7. **回调隔离的测试含义**：`pcall` 掉的断言不会让用例失败，测试必须记录结果后再断言（§3.1 的 ⚠）。
8. **修了一个自己暴露的 bug**：`dispose` 会清空 `_waiters` 而**不**回调它们 → 排队中的
   `Repo:refresh(cb)` 调用方永久挂起（探针复现：`waiter called=false`）。
   现在 `_mark_deleted` 会先以 `repository deleted: <root>` 释放在排的 waiter，
   再广播 `on_delete`（顺序很重要：manager 在后者里才 `dispose` 并清空列表）。

## 7. 独立代码审查（M2，code-reviewer）与修复

审查结论：无阻断性问题；列出 1 critical + 3 major + 6 minor + 4 测试/文档问题。
本节记录每一条的**定论**（接受并修复 / 经核实不成立 / 有意不修）：

| 级别 | 审查意见 | 定论与动作 |
|------|---------|-----------|
| critical | `attach`/`detach` 竞态：检测异步，晚到的回调会把已释放的 ref 重新绑定 → 仓库永远泄漏 | **成立，已修**：`repo_manager._gen` 每 ref 一个**世代号**，`detach` 递增；回调世代不符则拒绝绑定并以 `attach cancelled: ...` 回调（用例 `detach that races an in-flight attach`） |
| major | worktree/submodule 的 `.git` 是文件 → 元数据监听被静默跳过，`git add` 永远看不到 | **成立，已修**：新增适配器钩子 `system.metadata_dir(root)`（git 由 `gitdir:` 解析，`marker_at` 与它共用 `gitdir_at`），`metadata_path` 成为真正的监听目标；用例在 worktree 里做 `git add` |
| major | `exec.run` 的超时路径在 fast-event 上下文回调（违反 D16） | **成立，但范围更大**：实测 `vim.system` 的**退出回调也是 fast-event**，不只是超时路径。因此在 `finish` 里**统一** `vim.schedule`；新增 `exec_spec` 用例直接断言 `in_fast_event() == false` 且回调里能 `nvim_buf_set_lines`（这也是 M3 渲染器能否工作的前提） |
| major | 命令飞行中 dispose → 完成回调会 `_schedule_retry()` 在已终结对象上建 timer，破坏「句柄为零」 | **成立，已修**：完成路径先查 `is_deleted`；`_schedule_retry` 自身也加了守卫；新增 stub 用例（确定性） |
| minor | `refresh_now` 重置 `error_count` 但不清 `last_error`，警告语义不一致 | **行为有意保留**（`last_error` 兼作「本失败串已报过」的标记，手动重试不再喷警告，错误由调用方 `cb` 拿到）；**已改写注释**说明，并在用例里加注释防止后人「修坏」 |
| minor | `_apply_status` 无条件清 `is_dirty` + `deep_equal` 对顺序敏感 | **部分接受**：改为用 `status_map` 对比（顺序无关）；`is_dirty` 那条是自愈的（排队的去抖仍会跑，渲染器也不会被错过），不修，已注释说明 |
| minor | Windows 大小写只在 `relpath` 处理，map 键不折叠 | **成立，已修**：新增 `base.path_key`，`status_map`/`_by_root`/`_by_ref`/查询统一折叠；用例翻盘符字母验证 |
| minor | `_do_refresh` 不 pcall `system.status`，同步抛出会卡死管线 | **成立，已修**：`pcall` 包住调用 + `done` 幂等闸 |
| minor | `dispose()` 公开却不通知 manager | **经核实不成立**：`dispose → _mark_deleted → emit(on_delete)` 就会让 manager `_remove`（`_remove` 又幂等），已把这个保证写进 `dispose` 的文档注释 |
| minor | fs 事件报错只记 debug，死句柄永久保留 | **成立，已修**：改为 `warn` + 释放句柄（目录再现时重新拾起） |
| test | waiter 释放在排用例依赖 fs 事件跑赢去抖窗口 | **已改为确定性**：改用同步 `detach()` 触发同一条 `_mark_deleted` 路径 |
| test | 覆盖缺口（on_error / 已删除后的 `refresh` / fast-event 分支 / worktree / attach 竞态 / ≤1s） | **基本补齐**（见 §5 的附加行）；`refresh_now` 的 `vim.in_fast_event()` 分支仍未有直接用例，已记入 05 §3 未覆盖清单 |
| test | `vim.notify` 可能因断言失败而保持被 stub | **已修**：`pcall` 包住用例主体，先恢复再重抛 |
| doc | 计数漂移（13/66 vs 实际） | **已修**：总数改为 78，并保持各文件一致 |

全量（M2 收尾时）：**81 用例，0 失败**（`status_type` 4 + `config` 7 + `exec` 7 + `vcs_git` 16 +
`vcs_svn` 18 + `vcs_registry` 8 + `repo` 21；repo 的最后 3 例是第二轮回归用例）。
M3 之后全量为 **114**（+ `renderer` 15 + `sidebar` 18，见 03 §6/§7）；M4 之后 **167**（+ `actions` 24 + `cli` 17 + `autocmds` 10 + `exec` 2，见 04 §6）。
M5 之后 **174**（+ `doc` 7，见 05 §6）——`make test` 与 `scripts/run_tests.sh` 等价。

M4 在 `repo_manager` 侧新增了两个入口：

- `ensure(path, cb)`：命令层的「现在就作用在这个路径上」。按**最近的 marker** 解析仓库（而不是 `get_by_path`
  的「最深已 attach」），并用 `cmd:<root>` 引用把仓库钉到会话结束（每仓库一个引用，见 D32）。理由与踩到的坑见 04 §7.1。
- `hold(ref, repo)`：给已经拿着 Repo 的消费者加一个引用——不探测、不发命令。侧边栏用它成为 D18 里说的那个
  引用持有者（`sidebar:<system>|<root>`，缓冲区活多久就持多久；M4 审查的 major：没有这条引用，关掉仓库里
  最后一个文件会把用户正在看的侧边栏一起拆掉）。

### 第二轮（M2 收尾后的全量复查）

| 级别 | 发现 | 定论与动作 |
|------|------|-----------|
| major | `relpath(root, root) == nil` — `get_by_path` 判「根不在根内」，`active()` 在「cwd 即仓库根」（`cd repo && nvim`）时解析不到 | **成立并实证，已修**：等值分支返回 `''`（探针复现 nil 后修复）；回归用例 |
| major | `_remove`/`dispose_all` 不推进世代号 — 检测在飞时仓库消失或会话退出，晚到回调照样建仓（句柄不外泄的不变量破洞，且 ref 从未绑定时连 `_gen` 条目都没有） | **成立，已修**：`attach` 进入即递增自己 ref 的世代号（**最新者胜**，同时修掉「两个并发 attach 由谁后完成谁定」）+ `_remove` 对被释放的每个 ref 递增 + `dispose_all` 递增**模块级 epoch**；确定性用例（attach 与 dispose 同 tick，回调必晚于其执行） |
| minor | `_schedule_retry` 的已排队回调在取消后仍会多跑一轮 | **已修**：`armed` 判定 — 被取消/被替换的 timer 不再触发 refresh |
| minor | `exec.run` 超时防御分支索引已被置 nil 的 timer（契约真变了会 raise 而不是关句柄） | **已修**：本地副本 + 判空 + `new_timer` 判空 |
| minor | `refresh_now` 不取消在途防抖 — 窗口内夹一次手动刷新 = 同批变更跑两遍 | **已修**：`_do_refresh` 起跑前 `_refresh_cancel()`（从防抖回调里调用也安全：timer 已触发，cancel 只关句柄+失效世代） |
| minor | waiter 在飞行中注册拿到「上一轮」结果（快照可能早于请求） | **保留并文档化**：错误即时送达（M4 动作回调依赖）比等下一轮更新鲜更重要；语义写进 `refresh` 文档 |
| minor | 更新期间**丢弃** metadata 事件 — 完全落在 status 运行窗口内的 `git add` 永远丢失 | **已修**：改为置 `is_dirty + has_pending`（在飞轮结束多跑恰好一次补跑；不 arm 防抖，防「每轮 status 都重写元数据」的 VCS 自激） |
| minor | `get_by_path` 对每仓两次冗余 normalize（`active()` 每 BufEnter 都跑） | **不修**：仓库数是个位数，`relpath` 的正确性（文件系统根、大小写）比这点开销值钱；记入已知取舍 |
| minor | git `!!` / svn 列 1 `X`/`I` 在当前采集参数下不可达 | **已加注释**：标明前向兼容意图，防止后人误删或误以为已采集 |

审查同时给出 15 条「核实过无问题」清单（防抖句柄池、`_do_refresh` 防重入、waiter 释放顺序、
exec 恰好一次回调、git `-z`/svn 列解析、`gitdir:` 解析、监听集增删同步、config 合并等），
全文在会话记录中；抽查未见「一轮已修的 5 项」出现回归。
