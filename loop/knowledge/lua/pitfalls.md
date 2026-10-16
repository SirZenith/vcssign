# 踩坑总表（Lua / nvim / 工具链）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §6.3 与
> `loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md` §6。原文抽取，未做改写。

**要点**：`and/or` 在空值上会穿透；循环 `require` 要用惰性 `require`；忘了 `M.__index = M` 是所有方法
变 `nil` 的经典事故；luv 回调在 fast-event 上下文，必须 `vim.schedule` 才能碰 vim API；
`pcall` 掉的断言**不会**让用例失败（测试里要记录结果后再断言）。

---

*来源：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md`，原文 `### §6.3 已知坑与实测（别重踩）`*（标题层级已下移一级）

#### §6.3 已知坑与实测（别重踩）

- **libuv 不报告被监听目录自身消失** → 存活探测必须挂在**父目录**上（见 §6.1）。
- `svn patch` 的路径剥离（**Step 9 实测更正**）：git 风格头（`--- a/x`）配 `--strip 0` **能正常应用**
  （打印 `U <file>`），裸头也可以；`--strip 1` 才会冲突，`--strip 2` 报 `E195018: Cannot strip 2 components`。
  旧文写「只吃裸头」，是把一次**未提交文件**（只 `svn add` 过、BASE 里还不存在）的实验当成了头风格问题。
  所以 `hunk.build_patch` 只产一种头就够，svn 侧不需要切换风格，`vcs/svn.lua` 的 `apply_patch` 一行没改。
- `svn patch` **冲突时退出码仍然是 0**（stdout 打 `C <file>` + `rejected hunk`，并写 `<file>.svnpatch.rej`）：
  必须解析 stdout 才算成功 —— `vcs/svn.lua` 的 `apply_patch` 已经这么做（`e6c4f1b` 之后），Step 9 只是验证。
- `git show HEAD:<f>` 在 **unborn HEAD** 上报 `fatal: invalid object name 'HEAD'.`（不是空基线），只有 `:<f>` 可用。
- `vim.text.diff({a}, {b}, { result_type = 'indices' })`：1 基 `{start_a, count_a, start_b, count_b}`，
  `count` 可为 0（纯插入/删除）；`on_hunk` 返回负数会抛 `E5113`（**不能**用它中断）。
- `vim.text.diff` / `vim.diff` **只收字符串**（传列表 → `bad argument #1 (expected string)`，Step 10 实测）；
  `vim.split(s, '\\zs')` 不分字符（返回 `{ s }`），要 `vim.fn.split(s, '\\zs')` 才逐字符。
- **xdiff 的 `indices` 两端可能带公共前后缀**（见 §6.1 Step 10 第 2 条）：直接按 `indices` 画行内区间会多
  画一块，先剪 a / b 段序列的公共前后缀。
- `diff.linematch` 默认已改成 `false`：它是二次型，实测 500 行全改 1.1s、2000 行 69s、5000 行 OOM。
- **`signcolumn` 是窗口选项**：`vim.wo[bufnr]` 写不进，要对 `win_findbuf(bufnr)` 的每个窗口设置。
- **`on_lines` / `on_reload` 在 textlock 里**：只能置标记，刷新必须经 `debounce` 回主循环（D19）。
- svn blame 没有 time/summary，本地未提交行的 revision 是 `-`；`svn log` 在 WC 上只到 BASE（要看 URL）。
- headless nvim **不发** `VimResized` / `FocusGained` 等事件 → 测试用 `nvim_exec_autocmds` 驱动；
  `DirChanged` 的 scope 在 `v:event` 里（回调参数里没有）。
- **headless 不会自己触发 `CursorMoved`**：`nvim_win_set_cursor` 不产生事件，所以「移动光标 →
  blame 跟着动」这类用例要显式 `nvim_exec_autocmds('CursorMoved', { buffer = bufnr })`
  （`FocusGained` / `DirChanged` 同理，见下一条）。
- **浮窗不在 `bufwinid()` 的名单里**：它没有窗口槽位，`vim.fn.bufwinid('vcssign://…')` 返回 -1
  （`Invalid window id`）。要读浮窗内容就遍历 `nvim_list_wins()` 找
  `nvim_win_get_config(win).relative ~= ''` 的那个。
- **`svn cat -r 1 <file>` 可能报 `E195012: Unable to find repository location … in revision 1`**：
  文件是后来才进版本库的。和某个历史 rev 比时要挑该文件确实存在的 rev（spec 里用 `HEAD`）。
- **`virt_text` 挂在 `eol` 上要自己带空格**（`{ ' ' .. text .. ' ' }`），否则装饰和源码行黏在一起。
- **`on_detach` 与 `on_lines` 都不在 fast context**（Step 13 探针实测 `vim.in_fast_event() == false`）：
  `nvim_buf_attach` 的三个回调都在主循环里跑，所以 `M.detach` 直接在 `on_detach` 里调是安全的；
  D19「只能置标记」的边界只对 textlock 里的 `on_lines` / `on_reload` 成立。
- **「默认面答应了、实现没跟上」这类问题是 `doc_spec` 查不出来的**：`doc_spec` 只断言名字在
  `doc/vcssign.txt` 里出现（`hq` → `setqflist` 也在 `keymap.ACTIONS` 之外活了一整个里程碑）。
  任何「文档承诺 + 键位/子命令」的组合都要配一条**语义**断言（Step 13 给默认键位补的就是这条）。
- `vim.notify_once` 按**消息文本**去重：要「每个动作只提示一次」就得把动作名编进消息
  （`keymap.dispatch` 的 `… is not implemented yet` 就是这么做的）。
- 测试卫生：每个用例包 `guarded(fn)`（失败也清场）；`helpers.capture_notify` 必须**排空 `vim.schedule`**
  再还原 `vim.notify`；`helpers.uv_count` 只数**未 closing** 的句柄；跑测试前 fixture 要在（`make fixtures`），
  `temp/_spec` 由 `helpers.cleanup()` 清。
- 写探针：`cd` 仓库根后 `nvim --headless -u NONE -l temp/probe_X.lua`（`-u NONE`，别依赖用户配置）。
- **子 agent 沙箱**（本机实测）：可能拒 `sh` / `rm` / `git commit` / `nvim --headless`。可用替代：
  `make test` / `make format` / `make lint` / `git add <显式路径>` / `git commit -F <消息文件>`；
  探针写进 `temp/` 交给主 agent 跑。**只有主 agent 的 shell 是无限制的**，改动落地与验证留在主 agent 做。
- 长命令会被 harness 截断（heredoc 尤甚，超过约 7KB 会被切在半句上）：长文件分块写，或改用「按行号手术」
  的 python 补丁（`assert src.count(old) == 1` 守卫 + `io.open(..., encoding='utf-8', newline='')` 回写）。
  `edit` 工具对「尚无观察」的文件可能拒绝改，此时同样走 python 补丁。
- **在 `WinEnter` 里给窗口写 `'signcolumn'` 会踩到别的插件**（用户实测 noice：`:Noice history` 报
  `nui/split/init.lua:170` → `attach.lua:302`（`vim.wo[win].signcolumn = sc`）`C: in function '__newindex'`）：
  `vim.wo[win].signcolumn = <同一个值>` **也会触发 `OptionSet`**（实测：同一个值写三次 = 三次
  `OptionSet`），而 nui 开窗是**在自己的 `nvim_win_call` 里**执行 `:vsplit` 的，那串 `OptionSet`
  处理器一炸就沿着我们写窗口选项那一行往上冒。当时的修法是「先读后比、值相同就不写」（`d743bba`，`attach_spec`
  三条用例）—— **M6 之后这条路径连同 `set_signcolumn` / `reapply_signcolumn` / `WinEnter` 订阅一起删掉了**
  （见 §6.1 末两条）：`signcolumn` 变成布尔、插件从不写窗口选项，这一类问题不再有机会发生。

- **异步取数回来时，当初的许可可能已经失效**：探针（`temp/probe_focus.lua`，已删）里
  `:vsplit` + `:enew` 换走焦点后 `blame.clear(bufnr)`，60 ms 后 extmark 自己回来了 —— 一个仍在飞的
  `git blame` 回调（栈：`exec.lua:149` → `git.lua:306` → `blame.lua:197` → 写 extmark 的
  `blame.lua:284`）在 `vim.wait` 里跑完了，而它只判了「窗口与行号没变」。修法：把「现在还要不要这个
  装饰」收成一个 `still_wanted(bufnr, win, lnum)`（开关、插入模式、窗口、行号、`use_focus`、折叠），
  **取数前后各判一次**；`blame_spec` 的 `use_focus keeps an unfocused window bare` 用例就是它。
  凡是「先取数、再落笔」的装饰（blame / preview / 将来的别的）都要这么写。
- **`%R` 的单位表照抄 gitsigns**：一年是 `365 * 24 * 60 * 60`。写成 `365 * 30 * 24 * 60 * 60`
  （= 30 年）时，400 天前会被说成 `13 months ago`；`blame_formatter_spec` 的
  `relative_time is gitsigns %R` 钉住这条。
- **`vim.tbl_extend` 表达不了「删掉一个字段」**：Lua 表里没有 nil 值，`{ summary = nil }` 就是空表，
  覆盖后默认值还在。测「适配器答不出的字段」要么造一个干净的输入表，要么用 `false` 之类哨兵再显式剔除。
- **别经 heredoc 传 Lua 转义**：把 `\n` 写进 python 补丁脚本的字符串里（工具参数本身是 JSON），
  落到 Lua 文件里就是一个真的换行 → `stylua` 报 `unclosed string`。探针与 spec 用 `write` 工具直接写，
  或在 Lua 里用 `%c` + `10` 代替 `\n`。

---

*来源：`loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md`，原文 `## 6. 实测与偏差记录（回写）`*（标题层级已下移一级）

### 6. 实测与偏差记录（回写）

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
