# 02 · 仓库运行时：进程执行、Repo 对象、缓存、FS 监听、刷新管线（P1）

> 承接 01 的数据通路，把它变成「活」的：状态有缓存、变更自动发现、
> 并发收敛到一条防抖刷新管线。本层完成后，UI 层只管消费事件。
>
> **状态：✅ 已完成**（M2）。验收 02 §5.1–5.5 全部有自动用例，66/66 spec 全绿。
> 与初版计划的偏差见 §6（全部为实测驱动）。

## 1. 交付物

| 文件 | 职责 | 状态 |
|------|------|------|
| `lua/vcssign/exec.lua` | `vim.system` 封装：参数经验（gitsigns `git/cmd.lua`）+ 统一错误结构 | ✅ M1 提前落地 |
| `lua/vcssign/config.lua` | 加 `watch` / `update_debounce_ms` / `retry_delay_ms` / `retry_max_ms` / `log_level` | ✅ |
| `lua/vcssign/log.lua` | 分级日志：debug/info/warn/error，全部经 `vim.schedule` → `vim.notify` | ✅ 新增 |
| `lua/vcssign/util.lua` | `is_dir` / `subscribe` / `emit`（隔离监听器异常） | ✅ 新增 |
| `lua/vcssign/debounce.lua` | 移植 gitsigns `debounce_trailing`（MIT 注明）+ `cancel` 返回值（见 §3.3） | ✅ |
| `lua/vcssign/repo.lua` | `Repo` 对象：状态缓存 + FS 监听（句柄池化）+ 刷新管线 + 退避重试 + `dispose` | ✅ |
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
---@field status vcssign.StatusEntry[]          # 最近一次**成功**的列表
---@field status_map table<string, vcssign.StatusEntry>  # 绝对路径 → entry
---@field refs table<string, true>              # 持有它的引用令牌
---@field is_dirty boolean                      # 有变更待刷新
---@field is_updating boolean                   # 刷新中（防重入）
---@field has_pending boolean                   # 刷新期间又来了一次请求 → 跑完补跑
---@field is_deleted boolean                    # 仓库消失 / 已 dispose
---@field has_loaded boolean                    # 至少成功跑过一次（剪裁用）
---@field error_count integer                   # 连续失败次数（退避指数）
---@field last_error string?
---@field fs_handles table<string, uv.uv_fs_event_t>   # 监听路径 → 句柄
---@field fs_handle_pool uv.uv_fs_event_t[]            # 句柄池（复用）
M.new(system, root) → Repo
```

> ⚠ 与初版计划的两处差异：**没有** `fs_timers` / `fs_timer_pool`
> （去抖只做一层，见 §3.3）；字段用 `root` 而非 `root_dir`（与 01 的适配器术语一致）。

### 3.1 状态 API（回调链，供 UI 消费）

```lua
Repo:refresh(cb?)      # 走防抖窗口；cb(err, entries) 在本轮结束时调用一次
Repo:refresh_now(cb?)  # 跳过防抖（attach 首刷、动作后强制刷新）；并重置退避计数
Repo:mark_dirty()      # 只置脏 + 排队（FS 事件/autocmd 用）
Repo:entries()         # 缓存列表（**不排序**，见下）
Repo:get_entry(path)   # 绝对且已归一化的路径 → entry（渲染热路径，免 normalize）
Repo:get_status(path)  # 同上，只取 FileStatus（无变更 → nil）
Repo:on_update(fn)     # 一轮刷新「成功且有变化」→ fn(repo)；返回 unsubscribe
Repo:on_error(fn)      # 一轮刷新失败 → fn(err, repo)
Repo:on_delete(fn)     # 仓库被判定消失 → fn(repo)
Repo:dispose()         # 停监听/定时器/订阅，终态
Repo:start()           # 开始监听（manager 建仓时调用）
```

> ⚠ **偏差**：初版说 `entries()` 返回「已按 03 的排序规则排好」。
> 实际**不排序**：排序与分组依赖 git 三域 / svn 单域的自适应规则，属于 03 渲染层，
> 放这里会变成两份实现。渲染层拿到的是「解析顺序 + 稳定的相对路径」。
>
> ⚠ `refresh*` 的回调由 `pcall` 隔离（见 §3.3），
> 因此**回调里不要写断言**：测试要记录结果、在用例体内断言（spec 里已按此写）。

### 3.2 FS 监听（自动发现变更）

监听集（`_init_watch`）：

| 路径 | 递归 | 为什么 |
|------|------|--------|
| `root` | 否 | root 层的文件增删/改名 |
| `root` 的**直接子目录** | 否 | ⚠ 偏差：不监听就无法发现子目录里的编辑（最常见的情况）；只展开一层，不做 oil-vcs-status 式全量递归 |
| `root/.git`（或 `.svn`） | 是（非 Linux） | index / wc 元数据变化 —— 状态域翻转的主信号 |

> **实际监听的是 `metadata_path`**，不一定是 `<root>/<keyfile>`：git worktree / submodule 的
> `.git` 是**文件**，真正的 index 在 `<main>/.git/worktrees/<name>/index`（在仓库之外）。
> 由适配器的可选钩子 `system.metadata_dir(root)`（01 §3）解析，缺省回落到 `root/keyfile`。
> 没有这个解析，`git add` 在 worktree 里就永远发现不了（有个专门用例钉住）。

- libuv 在 Linux 上不支持递归 fs_event（inotify 无此模式），那里 `.git` 退化为非递归；
  `.git/index` 是 `.git` 的**直接子项**，所以关键的暂存域信号仍然能拿到（已实测）。
- `_sync_watch_set`：root 层出现新目录 → 补监听；被监听目录消失 → 释放句柄。
- 回调里**只做两件事**：`is_dirty = true` + 重置去抖 timer（实现上就是 `mark_dirty`）。
  绝不直接跑命令。
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
 mark_dirty() → is_dirty = true → debounce_trailing(update_debounce_ms=300)
        │                              （vimschedule 后调用）
        ▼
 _do_refresh()
   ├─ is_updating → has_pending = true，返回（跑完立即补跑 → 收敛）
   ├─ is_updating = true  ← **先置位，再发命令**
   ├─ system.status(root, cb)
   │     成功 → deep_equal 剪裁 → 存 status/status_map → is_dirty=false
   │            → error_count=0 → 清退避 → 变化了才 emit(on_update)
   │     失败 → 保留旧缓存 → error_count++ → 同一失败串只 warn 一次
   │            → 指数退避重试（1000 × 2^(n-1)，封顶 30000，成功后取消）
   └─ flush waiters → has_pending ? 再跑一轮 : 结束
```

- 「防重入 + 补跑」= gitsigns `throttle_async(schedule=true)` 语义，用回调实现（D9）。
- **先置 `is_updating` 再调命令**：`system.status` 通常是异步的，但能力不支持 / 参数校验失败是
  **同步**回调，先调后置会被同步回调清掉标志，然后真正的异步回调再跑一轮 → 并发刷新。
- **剪裁**用 `vim.deep_equal(旧, 新)`；但**首轮永远通知**（否则干净仓库 `{} == {}` 会让侧边栏永远空白）。
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
- **剪裁用 `status_map` 对比而不是数组**：`vim.deep_equal(旧map, 新map)` 与入口打印顺序无关，
  避免 svn 输出顺序波动引起无意义重渲染。
- **路径键在 Windows 上大小写折叠**（`base.path_key`）：`status_map` / `_by_root` / `_by_ref`
  的键统一折叠，否则 `D:/Repo` 与 `d:/repo` 会被当成两个仓库（两个缓存 + 两个监听）。

## 4. repo_manager.lua（生命周期编排）

```lua
M.attach(ref, path, cb)   # ref 是不透明令牌（"buf:3" / "sidebar" / "cmd"）
                          # → detect(01) → 找/建 Repo → start 监听 → 首刷 → cb(err, repo)
M.detach(ref)             # 释放一个引用；最后一个引用才 dispose
M.dispose_all()           # VimLeavePre：全部释放，句柄清零
M.get(root) / M.get_by_path(path) / M.active()
M.all() / M.count() / M.ref_count(root)
M.on_repo_attached(fn) / M.on_repo_detached(fn)
```

- 同一 root 只有一个 `Repo`，多个 buffer 共享缓存与监听（引用计数）。
- **快速路径**：`registry.detect`（纯 marker 扫描，不起进程）命中已知 root → 直接复用；
  且若该 repo `has_loaded and not is_dirty` → 直接回缓存、**不起进程**。
  注意这条路径下 `cb` 是**同步**调用的（已在文档注释里写明）。
- `ref` 换仓库（buffer 换目录）→ 先解绑旧的再绑新的，不会泄漏引用。
- 仓库消失（§3.2）→ `repo:on_delete` → manager 移除 + `dispose()` + 广播 detached。
- 所有清理路径都汇到 `Repo:dispose()`：停 fs_event 句柄、关去抖/退避 timer、清订阅与 waiters。

## 5. 验收标准（全部有自动用例，见 `test/repo_spec.lua`）
| # | 场景 | 用例 |
|---|------|------|
| 5.1 | 改文件 → ≤1s 内缓存出现该文件；撤销 → 收敛消失 | 「a worktree edit reaches the cache through the filesystem watcher」（还断言 on_update 恰好 1 次/2 次） |
| 5.1b | 子目录里的编辑也能发现 | 「an edit in a direct subdirectory is discovered too」 |
| 5.2 | 连续 10 次快速写 → **至多 2 轮**真实 `git status` | 「ten rapid writes collapse into at most two status runs」（`exec.run` 计数，实测 1 轮） |
| 5.2b | 同一窗口内的多个 `refresh(cb)` 只跑一轮且每个 cb 都被调用 | 「refresh requests inside one window are served by a single run」 |
| 5.3 | `git add` → `.git/index` 变化 → index 域翻转 | 「staging flips the index domain through the .git watch」（断言 `index=modified, worktree=nil`） |
| 5.4 | 删/移 `.svn`（及 `.git`）→ dispose，句柄与 timer 归零 | 「a vanished .git disposes …」「deleting an svn working copy cancels its watcher too」（`vim.uv.walk` 计数前后相等） |
| 5.5 | 命令失败 → 保留旧缓存 + 只 warn 一次 + 退避重试，不抛异常 | 「a failing status keeps the cache, warns once and backs off」+「the backoff retry recovers without any user input」（后者验证重试**真的**自动恢复） |
| §4 | 引用计数：第二个引用复用同一对象且不起进程；最后一个释放才 dispose | 「references share one repo and the last release disposes it」 |
| §4 | `dispose_all()` 后无残留句柄 | 「dispose_all leaves nothing behind」 |
| §4 | `active()` 按当前 buffer 解析 | 「active() resolves the repository of the current buffer」 |
| 附加 | **排队中的 `refresh(cb)` 不会因仓库消失而永远挂起** | 「a queued refresh callback is released when the repository goes away」（先探针确认旧实现会静默丢弃，再修；现已改为确定性用例 + 后续 `refresh`/`refresh_now` 立即报错） |
| 附加 | **attach 与 detach 竞态不会泄漏引用**（检测是异步的） | 「a detach that races an in-flight attach does not leak a reference」—— 修前：已释放的 ref 会被晚到的回调重新绑定，仓库与其监听永久存活 |
| 附加 | **命令飞行中被 dispose，晚到的结果不产生任何副作用** | 「a status run that reports after dispose changes nothing」（stub 适配器 + `vim.defer_fn`，完全确定性） |
| 附加 | **linked worktree 里的 `git add` 能被发现**（`.git` 是文件，index 在仓库外） | 「staging inside a linked worktree is picked up」—— 修前该用例会超时 |
| 附加 | Windows 路径大小写不敏感 | 「path lookups are case-insensitive on Windows」（`D:`/`d:` 翻转后 `get`/`get_status` 仍命中） |
| 附加 | §5.1 的 **≤1s 延迟预算** | 用例 2 里用 `vim.uv.hrtime()` 实测断言（此前只验证了收敛） |
| 附加（二轮） | **仓库根目录本身解析回该仓库**（`cd repo && nvim` 时 `active()`） | 「the repository root itself maps back to the repository」— 修前 `relpath(root, root) == nil`（前缀比根长一字符，探针实证） |
| 附加（二轮） | **`dispose_all` 之后不再诞生仓库**（检测在飞时会话退出） | 「dispose_all cancels an attach that is still detecting」— 修前世代号只覆盖 `detach` 路径，晚到回调会在销毁后再建 Repo |
| 附加（二轮） | **防抖窗口内的手动刷新不跑两遍** | 「a manual refresh inside the debounce window is not run twice」— 修前 `refresh_now` 不取消已武装的防抖 |
| 附加 | `on_error` 订阅真会被调用 | 失败用例新增 `eq(errors, 1)`, `eq(errors, 2)` |

## 6. 实测与偏差记录（回写）

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
M3 之后全量为 **107**（+ `renderer` 13 + `sidebar` 13，见 03 §6/§7）。

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
