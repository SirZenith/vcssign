# libuv 监听 与 `vim.system`（实测语义）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` §2/§3.2、
> `loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md` §6.1、
> `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §5.1/§5.5。原文抽取，未做改写。

**要点**：`uv.fs_event`（Lua 侧）**不递归**、且**从不报告被监听目录自身消失**——所以存活探测要挂在父目录上；
删掉目录后必须先 `stop()` + `close()` 才能止住事件风暴；`vim.system` 的**退出回调在 fast-event 上下文**
（要 `vim.schedule_wrap`），`spawn` 失败会直接抛（要 `pcall`），超时定时器要在 spawn **之前**建好。

---

*来源：`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md`，原文 `## 2. exec.lua（进程执行封装）`*（标题层级已下移一级）

### 2. exec.lua（进程执行封装）

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

---

*来源：`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md`，原文 `### 3.2 FS 监听（自动发现变更）`*（标题层级已下移一级）

#### 3.2 FS 监听（自动发现变更）

监听集（`_init_watch`，M6 Step 2 + `f1d1735` 修正后共两项）：

| 路径 | 递归 | 为什么 |
|------|------|--------|
| `metadata_path` | 是（非 Linux） | index / wc 元数据变化 —— 这是 Repo 唯一需要的信号（D38） |
| `root` | **否** | **只作存活探测**：libuv 从不报告「被监听目录自身消失」，见下 |

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

---

*来源：`loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md`，原文 `## 6.1 `exec.run` 的超时定时器（M4 实测修正）`*（标题层级已下移一级）

### 6.1 `exec.run` 的超时定时器（M4 实测修正）

计划里的顺序是「先 `vim.system`，再建并武装超时定时器」。实测发现 **`vim.system` 的退出回调可能在本函数返回之前就跑**
（立刻失败的进程，例如 `cwd` 不存在），于是那次 `finish` 看到 `timer = nil`（还没有定时器可关），
定时器随后被武装、却再也没人关它——直到 15s 后超时回调发现自己 `finished` 才自我关闭。
期间它是一个活着的、已武装的 handle（`autocmds_spec` 的 `VimLeavePre` 用例抓到的就是这个）。

改为**先建定时器再 spawn**（`proc` 预先声明为局部变量，超时回调里判空后再 `kill`）：`finish` 无论如何都能关掉它。
`test/exec_spec.lua` 的 7 个用例（含超时与「0 表示不限时」）在改动后仍全绿。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §5.1 `vim.system` 的 stdin 语义（→ D41 / D43）`*（标题层级已下移一级）

#### §5.1 `vim.system` 的 stdin 语义（→ D41 / D43）

| 输入 | 实测 stdout（`cat`） | 结论 |
|---|---|---|
| `stdin='a\nb\n'` | `len=4`，逐字节 `"a\nb\n"` | **原样写入，不吞不补** |
| `stdin='a\nb'`（无尾 `\n`） | `len=3` `"a\nb"` | **不会补尾换行** → 补丁必须自带结尾 `\n` |
| `stdin=''` | `len=0` | — |
| `stdin={'a','b'}`（`string[]`） | `"a\nb\n"`（len 4） | **逐元素自动补一个 `\n`** |
| `stdin={'a\n','b'}` | `"a\n\nb\n"` | 元素自带 `\n` 会再加一个 → 双换行 |

**`text` 只影响 stdout 解码，不改写 stdin 字节**：`cat` 一个 CRLF 文件，`text=true` → `len=4 "a\nb\n"`（CRLF→LF），
`text=false` → `len=6 "a\r\nb\r\n"`。用 `git hash-object --stdin` 对比：`stdin` 为 CRLF 时 `text=true`/`text=false`
哈希相同（`15238d98…`）；`stdin` 为 LF 时 `text=true` 仍得 LF 哈希 `e563bc26…`（未被转成 CRLF）。

**结论（照抄）**：喂 `git apply` 补丁**用单个 string**：`vim.system(cmd, {text=true, stdin=patch_str})`；
`patch_str` 必须自带结尾 `\n`；**不要用 `string[]`**（逐行加 `\n` 会破坏补丁）。`text=true` 不改 stdin，只是方便读 stdout。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §5.5 缓冲区 attach 与生命周期（→ Step 6，防 reload 丢状态）`*（标题层级已下移一级）

#### §5.5 缓冲区 attach 与生命周期（→ Step 6，防 reload 丢状态）

- **E1**：`nvim_buf_attach(buf, false, {on_lines=…})` + `nvim_buf_set_lines` → `on_lines` **同步触发**，
  参数 `(event, bufnt, tick, first, last, new_last, old_byte_size)`；触发时 **`changedtick` 已是新值**（传入 tick == `nvim_buf_get_changedtick`）。行号 0 基，`last` 端开。
- **E2（反直觉）**：`vim.cmd('edit!')` → **`on_detach`**，不是 `on_reload`（与 `api.txt` 文字描述相反）；bufnr 不变，
  **extmark sign 在 reload 后仍保留**。`:e`（非 bang，文件被外部改动）也是 `on_detach`。
  `on_reload` **只在整缓冲重载路径触发**：`vim.o.autoread=true` + 外部改文件 + `:checktime` → 每次 reload 触发一次，
  回调仍保持 attach，之后 `on_lines` 继续工作，extmark 亦保留。
  **结论**：**`:e`/`:e!` 后必须重新 attach**（`on_detach` + `BufReadPost` 双兜底）；只有 `:checktime`/autoread 路径依赖 `on_reload`。
- **E3**：`nvim_buf_delete(buf, {force=true})`/`:bwipeout` 会触发 `on_detach`（切 buffer 时也会看到）。
- **E4**：300ms 内连续 10 次 `nvim_buf_set_lines`（同步循环 / 间隔 30ms / `vim.schedule`）→ **`on_lines` 都触发 10 次，不合并**
  → 刷新必须自己防抖（`update_debounce_ms`）。
- **E5（换行约定必须一致）**：`joined = table.concat(get_lines(…), '\n')` = `"a\nb\nc"`（**末行无换行**）；
  `diff(joined, joined) = {}`；`diff(joined..'\n', joined) = {{3,1,3,1}}`；`diff("x","x\n") = {{1,1,1,1}}`。
  **结论**：buffer 侧与 git blob 侧必须用**同一约定**（推荐两边都 `concat(lines,'\n')`、末尾都不带 `\n`），
  否则末行永远凭空多一个假 hunk；`ignore_cr_at_eol=true` 可消除 CRLF/A 差异。

---

## M7 补记：长驻子进程与目录事件（`08` §2.7–§2.8、§3.5 S1）

**`vim.system` 的 stdin 默认不是可写管道。** `exec.stream(cmd, { cwd = root }, on_stdout, on_exit)` 要显式写
`stdin = true` 才能 `proc:write(…)`。漏掉它不会报错：`write` 静默失败（外层 `pcall` 吞掉），于是每个请求都等到
超时才回退到一次性 `show` —— 进程数看着正常、延迟翻倍，argv 直方图里 `git show` 与 `git cat-file` 同时出现
就是信号。另外流式回调**收尾时会给 `data == nil`**（不是空串），拼接前必须判空。

**非递归 watch 的 `filename` 可以是目录名。** Windows 上一次 `git add` 会让根 watch 依次收到
`(root, 'base.txt')`、`(root, '.git')`、`(<root>/.git, 'index.lock')`、`(<root>/.git, 'index')` 以及一堆
`objects\xx\tmp_obj_*`。想把「变了什么」收窄到具体文件，必须 `uv.fs_stat(path).type == 'file'`；把
`(root, '.git')` 当成某个文件路径，会把 `.git` 下面的 buffer 全部跳过——静默漏刷新。

**`recursive` 只是一个标志，不是 N 个句柄**（S1 实测，与最初猜测相反）：1200 文件的 svn 工作副本、
`.svn/pristine` 分 255 个分片，`uv_fs_event_t` 句柄数**始终是 2**（元数据 + root 存活探针），递归与否都是 2。
差别在**事件量**：一次 300 文件的 `svn commit` 里，`.svn` 递归收到 3135 次回调、非递归 1225 次、只听
`.svn/wc.db` 只有 1 次；多出来的全在 `.svn/pristine/**`，那里没有任何基线读取会看。所以适配器加了
`metadata_dir` + `metadata_recursive = false`（插件侧 `_on_fs_event` 调用 2985 → 1108），但没有走到「只听单个
文件」——目录监听对「文件被替换/移走」免疫，文件监听在各平台的寿命语义不一，不值得用静默变聋换最后一个数量级。
