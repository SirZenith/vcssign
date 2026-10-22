# 保存后 sign 偶尔消失：保存读到「保存前」的 status view（D53）

状态：`[x] 已完成`

## 1. 症状

[D51/D52](2026-10-21T14-53-19-signs-vanish-after-save.md) 之后仍偶发：编辑中的
文件 sign 显示正常，`:w` 之后**整个 buffer** 的 sign 消失；继续输入时新改动的
sign 又能正常出现；`:e!` 有时能把丢掉的标记带回来。git 与 svn 都存在
（两者被监听的元数据 —— `.git/index`、`.svn/wc.db` —— 都不因保存而移动）。

「偶尔」来自保存那一刻 status view 的状态：

- 视图比这个 buffer 的基线**新**（别的 buffer 已经按新戳重填过），或
- 保存发生在 attach 还没读完基线的时候。

## 2. 复现

五个用例都是确定性的（`test/autocmds_spec.lua`、`test/repo_spec.lua`、
`test/attach_spec.lua`），修复前分别超时或断言失败。

### 2.1 视图被别的消费者按「当前戳」重填，而 buffer 仍持有旧基线（T1）

`autocmds_spec` `'a save keeps the signs when the status view was repopulated at a newer stamp'`：

1. 提交三行文件并 attach（`base_stamp` = S0，基线来自 index）；
2. `repo:_drop_status()`，再跑一次真实 `status`，让视图在**当前**戳 S1 上重填，
   且内容为空（磁盘干净）——这正是「另一个 buffer 在 commit 之后刷新过」；
3. 把 `st.base_stamp` 改成更旧的值，然后**同一轮**里编辑并 `:w`。

### 2.2 保存发生在 attach 还没决定 `tracked` 时（T4）

`'a save while the attach still decides retires the clean view'`：视图是热的、
干净的空视图，但 `st.tracked == nil`（attach 的基线读取还没回来）。保存后基线
读到的仍是「保存前那份干净视图」。

### 2.3 `rev = 'HEAD'` 且工作区 == index，但 index != HEAD（T3）

`attach_spec` `'rev = HEAD keeps a staged hunk against HEAD, not against the buffer'`：
已 `git add`、未 commit 的文件在 `rev = 'HEAD'` 下应当以 HEAD 为基线显示
暂存改动；旧实现把「worktree 相对 index 干净」误当成「缓冲区就是 HEAD」。

## 3. 根因

### 3.1 `note_written` 先问 `baseline_moved`，再登记保存

`lua/vcssign/attach.lua`（D51 之后）：

```lua
if baseline_moved(st) then
  return M.refresh(bufnr)
end
local mode
if repo and st.path and st.tracked == true then
  mode = repo:note_save(st.path, true)
end
```

`baseline_moved` 回答的是「**store** 是否还是这个 buffer 读取时的那一个」
（`stamp_of(st) ~= st.base_stamp`），不是「**view** 是否还是」。另一个 buffer 把
`status_cache` 按新戳重填之后，`st.base_stamp` 仍是旧值 → `baseline_moved` 为真 →
**`note_save` 根本没被调用** → `load_base` 在新戳上命中那份「干净」的空视图 →
`from_buffer` 把刚保存的缓冲区当成自己的基线，diff 为空，sign 全灭。

### 3.2 `tracked == true` 的门把 attach 窗口排除在外

attach 期间 `st.tracked` 是 `nil`（要等 `load_base` 的回调才赋值），于是保存不会
登记到视图。随后（或在飞的）`load_base` 读到保存前的干净视图，同样走
`from_buffer`。这就是「保存后一直不回来」的那一类：下一次因别的原因重读基线才会
恢复（`:e!` 后磁盘比基线新，正是这种「有时能恢复」）。

### 3.3 给过期视图打补丁等于作伪证

`Repo:note_save` 只检查「缓存存在」，没检查 `status_stamp == _stamp()`。视图属于
另一个时刻时，把某个 entry 标成 `worktree = true`（或插入合成 entry）会让调用方
以为「这个保存已经被裁决过」，从而跳过本该发生的重读。

### 3.4 被保存作废的在飞查询仍自称 trusted

`_query_status` 的 `trusted` 只看 `self:_stamp() == stamp`。保存在查询在飞时退休
视图（`_drop_status`），但那个答案是在保存**之前**算出来的：store 没动，
`trusted` 仍为真，于是它仍然可以裁决 `from_buffer`。

注意：不能把 `_status_generation` 加进 `trusted`。查询期间到来的 fs 事件会退休
视图（`_drop_status`），但那份答案**已经包含**了这次移动（stamp 相等正是这个
意思）；`test/repo_spec.lua` 的
`'a view taken before the store moved is never believed about staging'` 明确要求
这种情况仍然 trusted。只有「保存」带来的是答案之外的时刻，所以只有保存会把
在飞的 waiter 标成 stale。

### 3.5 `from_buffer` 不看 `rev`

```lua
local from_buffer = clean
  and (st.rev == 'index' or st.rev == 'HEAD')
```

`clean` 只说明 worktree 相对 index/BASE 干净。`rev = 'HEAD'` 时 index 可能与 HEAD
不同（已 stage），此时缓冲区不是 HEAD 的文本；svn 的 BASE 是检出修订号，更不是
服务端 HEAD。于是 `rev = 'HEAD'` 的用户在「已暂存」状态下**必然**丢掉 worktree
层的标记，与保存无关。

## 4. 修复

1. **`lua/vcssign/attach.lua: M.note_written`** —— 先登记保存，再看基线是否移动。
   `note_save` 无条件调用（`tracked` 未知时传 `nil`，由仓库层决定保守行为）。
2. **`lua/vcssign/repo.lua: Repo:note_save`** ——
   - `status_stamp ~= self:_stamp()` 时 `_drop_status()` 并返回 `'fresh'`，
     不给过期视图打补丁；
   - `tracked == nil`（attach 未决定，且缺席 entry 无法区分 clean 与 ignored，
     见 D50）同样退休视图，交给下一次读取重新提问。
3. **`lua/vcssign/repo.lua: Repo:note_save`（deferred 分支）** —— 退休在飞查询前，
   把当前所有 waiter 标 `stale = true`。
4. **`lua/vcssign/repo.lua: Repo:_query_status`** ——
   `trusted = stamp ~= nil and self:_stamp() == stamp and not waiters[1].stale`。
5. **`lua/vcssign/attach.lua: load_base_status`** —— `from_buffer` 要求
   `trusted`，且 `rev = 'HEAD'` 只在
   `capabilities.staged_signs and staged == false` 时成立。

代价：常见路径（视图新鲜、`tracked` 已知）仍是 **0 次**仓库级查询，`note_save`
只打补丁；视图过期或 `tracked` 未知时才会多一次 status —— 这本来就是「不知道就
必须问」的情形，原先的省略会静默用错基线。

## 5. 测试

| 用例 | 文件 | 修复前 |
|---|---|---|
| `a save keeps the signs when the status view was repopulated at a newer stamp` | `test/autocmds_spec.lua` | `wait_for` 超时（hunks 变 0） |
| `a save while the attach still decides retires the clean view` | `test/autocmds_spec.lua` | 同上 |
| `a save against a view from a newer stamp retires it instead of patching it` | `test/repo_spec.lua` | `'noted' ≠ 'fresh'`，缓存未退休 |
| `a save that cannot say whether the file is tracked retires the view` | `test/repo_spec.lua` | `'noted' ≠ 'fresh'`，缓存未退休 |
| `rev = HEAD keeps a staged hunk against HEAD, not against the buffer` | `test/attach_spec.lua` | 基线变成 `base\none`（缓冲区），hunks 为 0 |

红色验证：只回退 `lua/`（`git diff lua/ > .pi-tmp-fix.patch && git checkout -- lua/`），
跑上述三个 spec，确认新用例失败；`git apply` 回来后全绿。

## 6. 验证

```
sh scripts/run_tests.sh      # === 335 tests, 0 failed ===
deps/luacheck.exe .          # 0 warnings / 0 errors in 51 files
deps/stylua.exe --check $(git ls-files '*.lua')   # exit 0
```

既有用例 `test/autocmds_spec.lua` 的保存用例、`BufWritePost re-reads the baseline
right away`（仍恰好 1 次 `attach.refresh`）、`test/repo_spec.lua` 的
`note_save` `'noted'`/`'deferred'` 语义、以及干净文件「absent entry 时基线就是
缓冲区」的快照用例全部保持绿色。

## 7. 影响与后续

- 被保存作废的在飞答案仍可能被渲染一次（`trusted = false` 时改走 `show`），
  随后的 `after_status` 重读会覆盖它；不会再出现持久的错误基线。
- 若「部分标记」指的是**同一 buffer 内只丢一部分行**（而不是整 buffer / 按文件
  丢），那是另一类问题（worddiff/preview 层或 `signs.place` 的跳过规则），需要
  另开文档并附上 VCS、`rev`、`:e!` 前后的 `attach.state(buf).base_text` 与
  `#attach.hunks`。
