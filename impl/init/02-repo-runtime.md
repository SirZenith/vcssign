# 02 · 仓库运行时：进程执行、Repo 对象、缓存、FS 监听、刷新管线（P1）

> 承接 01 的数据通路，把它变成「活」的：状态有缓存、变更自动发现、
> 并发收敛到一条防抖刷新管线。本层完成后，UI 层只管消费事件。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `lua/vcssign/exec.lua` | `vim.system` 封装：参数经验（gitsigns `git/cmd.lua`）+ 统一错误结构 |
| `lua/vcssign/debounce.lua` | 移植 gitsigns `debounce.lua` 的 `debounce_trailing`（MIT，文件头注明来源） |
| `lua/vcssign/repo.lua` | `Repo` 对象：状态缓存 + FS 监听（去抖、句柄池化）+ 刷新管线 |
| `lua/vcssign/repo_manager.lua` | `root → Repo` 映射、attach/detach 生命周期、全局事件分发 |

## 2. exec.lua（进程执行封装）

```lua
---@class vcssign.ExecResult
---@field code integer
---@field signal? integer
---@field stdout string
---@field stderr string

---@param cmd string[]            # {"git", "status", ...} 拼好的参数表
---@param opts { cwd: string, env?: table<string,string>, timeout?: integer }
---@param cb fun(err: string?, res: vcssign.ExecResult?)
M.run(cmd, opts, cb)
```

要点（全部来自 gitsigns `git/cmd.lua` 的实战经验，去 git 专用化）：

1. 基于 `vim.system(cmd, { cwd=..., text=true, env={LC_ALL="C", ...} }, cb)`。
2. Windows：`env.MSYS = "noglob"`、`env.CYGWIN = "noglob"`（防 MSYS2 展开路径参数）。
3. 超时（默认 `config.exec_timeout_ms = 15000`）via `SystemObj:kill()` + timer。
4. 返回统一结构；`code > 0` 时 `err = "exit <code>: <stderr 首行>"`，方便上层统一告警。
5. 一个小工具 `M.split_nul(stdout)`（git `-z` 输出用）与 `M.split_lines(stdout)`（gitsigns 的做法：去掉结尾空行）。
6. **不做** gitsigns 的 coroutine async 框架 —— 本插件所有调用点都是回调链。

## 3. Repo 对象（repo.lua）

一个仓库 root 一个实例。参考 oil-vcs-status `status/systems/vcs_system.lua` 的对象结构，但把「跑命令」从监听回调里剥离（它监听回调直接置脏、刷新走统一管线，这个分离要保留）：

```lua
---@class vcssign.Repo
---@field system vcssign.VcsSystem
---@field root string
---@field status vcssign.StatusEntry[]       # 最近一次成功拉取的列表
---@field status_map table<string, vcssign.StatusEntry>  # abs path → entry
---@field is_dirty boolean                   # 有变更待刷新（置脏模式）
---@field is_updating boolean                # 刷新中（防重入）
---@field fs_handles table<string, uv.uv_fs_event_t>     # 监听句柄（路径 → handle）
---@field fs_handle_pool uv.uv_fs_event_t[]              # 句柄池化复用（oil-vcs-status 模式）
---@field fs_timers table<string, uv.uv_timer_t>        # 按路径去抖 timer
M.new(system, root) → Repo
```

### 3.1 状态 API（回调链，供 UI 消费）

```lua
Repo:refresh(cb?)      # 刷新管线（见 §3.3），cb 在本轮结束后调用
Repo:entries()         # 缓存快照（列表，已按 03 的排序规则排好）
Repo:get_status(path)  # 单文件状态（侧边栏选中行 → 文件路径）
Repo:on_update(fn)     # 注册「一轮刷新完成 / 失败」回调（UI 重渲染靠它）
```

### 3.2 FS 监听（自动发现变更）

- libuv `fs_event`（oil-vcs-status `_watch_path` 模式）：**回调里只做 `self.is_dirty = true` + 重置一个去抖 timer**，timer 到期再调 `:refresh()`。绝不直接跑命令。
- 去抖 timer 也池化复用（oil-vcs-status `fs_timer_pool` 模式）。
- 监听路径（初版，差异化于 oil-vcs-status 的全递归）：
  - repo root（**非递归**：只发现 root 层文件增删 + 目录增删，防大仓库句柄爆炸）；
  - `.git` / `.svn` 目录（**递归**：捕获 index 变化、svn 元数据变化 —— 这是实际状态翻转的主信号）；
  - Linux：libuv 递归 fs_event 不可用（oil-vcs-status 有 `vim.fn.has("linux")` 分支，Windows/macOS 可递归）→ Linux 初版只监听 root + `.git/.svn` 顶层 + 依赖 04 的 autocmd 兜底刷新；不做 oil-vcs-status 的全子目录展开（性能代价），列为后续优化项。
- `.git` 上的 rename 事件（目录消失 = 仓库被删）→ 触发 detach（`is_deleted` 标志，oil-vcs-status 同款）。
- 监听变更的目录增删时动态调整监听集（`_update_fs_event_listener` 简化版：root 层新目录出现时补监听该目录）。

### 3.3 刷新管线（防抖 + 串行化）

两个层次，全部围绕 gitsigns `debounce.lua` 的 `debounce_trailing`（移植，注明 MIT 来源）：

```
FS 事件/autocmd/手动 refresh
        │  (per-repo key 去重)
        ▼
 dirty 置位 → debounce_trailing(fs_debounce=300ms) → Repo:_do_refresh()
                                                      │ is_updating 防重入：
                                                      │  正在跑 → 记 pending，
                                                      │  跑完立即再跑一轮（收敛）
                                                      ▼
                                          system.status(root, cb)
                                                      │
                                        成功 → 更新 status/status_map，
                                               is_dirty=false，
                                               通知 on_update 订阅者
                                        失败 → 保留旧缓存 + notify warn（首次）
                                               + 指数退避（2^n × 1s，封顶 30s，
                                               手动 refresh 重置）
```

- 「防重入 + 完成后补跑」等价于 gitsigns `throttle_async(schedule=true)` 的语义，但用回调实现（D9）。
- 刷新完成后做一次「**变更剪裁**」：新 status 与旧缓存 deep_equal 时**不触发** `on_update`（gitsigns `status.lua` 的 `vim.deep_equal` 比较同款策略），避免无意义重渲染。

## 4. repo_manager.lua（生命周期编排）

参考 gitsigns `attach.lua`/`cache.lua` 的生命周期编排（对象从「缓冲区」换成「仓库 root」）：

```lua
M.attach(path)         # detect(01) → 找/建 Repo → start 监听 → 首轮 refresh
M.detach(root)         # 停监听、清 timer、通知 UI 关闭该 repo 的侧边栏
M.active()             # 当前 buf/cwd 对应的 Repo（供 :Vcssign 默认目标）
M.on_repo_attached(fn) # 事件：新 repo 出现（UI 挂事件用）
```

- attach 触发点（autocmd 详见 04）：BufEnter（当前文件）、DirChanged、`:Vcssign` 显式命令。
- detach 触发点：仓库 root 被 rename/删除（§3.2）、用户命令、`VimLeavePre` 全量清理。
- 同一 repo 只有一个 Repo 实例；引用计数（多个 buffer 都指向同一 repo 时 detach 最后一个引用才真停）。
- 所有清理路径走同一个 `Repo:dispose()`（停全部 fs handle、close 全部 timer、清 on_update 订阅）—— 对齐 oil-vcs-status `dispose` 模式，**这是防句柄泄漏的验收点**。

## 5. 验收标准

1. `temp/git-repo` 中（用 05 的 fixture）：修改一个文件 →（300ms 去抖 + 管线）≤ 1s 内 `on_update` 触发且该文件出现在新 status 中；撤销修改 → 同样收敛消失。
2. 连续 10 次快速写文件（< 1s 内）→ 只触发**至多 2 轮**实际 `git status` 进程（去抖 + 串行补跑验证）。
3. `git add` / `git restore --staged` 后 `.git/index` 变化被 `.git` 监听捕获 → upstream 域翻转在侧边栏体现。
4. 删除 `temp/svn-repo/.svn` → repo 被 dispose，`uv.fs_event` 句柄与 timer 计数归零（spec 断言 `luv` handle 计数）。
5. 拔网线式的极端场景：命令失败 → 旧缓存保留 + 退避重试，不抛未捕获错误。
