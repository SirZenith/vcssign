# 编辑中的 sign 在保存后消失：status view 把保存后的缓冲区当成基线（D51/D52）

状态：`[x] 已完成`

## 1. 症状

在 svn 工作副本里编辑一个已跟踪文件，sign 列一开始正常显示改动；执行 `:w`
之后 sign 消失，随后继续输入时只显示「相对刚保存的内容」的改动，下一次
`:w` 又消失。子目录里的文件尤其稳定复现；仓库根目录的文件可能时好时坏
（保存触发的根目录 fs 事件会 retire view，但 `BufWritePost` 仍可能先读到旧
view）。关闭再重新打开 buffer 能恢复。

同一缺陷也存在于 git 工作树（`git status` 使用 `--no-optional-locks`，保存
不会移动 `.git/index` 的 stamp），只是报告来自 svn。

另有独立的 svn 症状：对一个文件执行 `svn add`（尚未 commit）后，整文件的
`untracked` sign 立刻消失。

## 2. 复现

```sh
# 已提交的 svn 工作副本，含 sub/nested.txt
nvim sub/nested.txt
```

1. 在文件里加一行：sign 列出现 change 标记。
2. `:w`：sign 消失。
3. 再加一行：sign 只标出「相对刚才保存内容」的新增。
4. `:w`：sign 再次消失；`:Vcssign refresh` 仍然为空。
5. 执行 `svn commit`/`svn update`（移动 `.svn/wc.db`）或重新打开 buffer 后恢复。

`svn add new.txt`（不 commit）复现第二种：`untracked` sign 变成空白，而不是
整文件 add 的 sign。

## 3. 根因

### 3.1 保存没有移动 metadata stamp

`Repo` 的仓库级 status view 以 baseline stamp（git `.git/index`、svn
`.svn/wc.db` 的 `stat_key`）为键；D38 之后只监听 metadata path，工作树本身
不监听。`BufWritePost` 之前走的是：

```
BufWritePost → attach.refresh → load_base → repo:status
```

保存不会移动 `wc.db`/`.git/index`，所以 `repo:status` 命中 attach 时缓存的
view。对 attach 时干净的文件，view 里**没有**该路径的条目；`load_base_status`
把「缺席」解释为 clean：

```lua
local from_buffer = clean
  and (st.rev == 'index' or st.rev == 'HEAD')
  and api.nvim_buf_is_loaded(st.bufnr)
  and not vim.bo[st.bufnr].modified
```

`BufWritePost` 触发时 buffer 的 `modified` 已经清零，于是 `from_buffer` 成立，
`st.base_text` 被设为**刚保存的缓冲区文本**。随后的 diff 自然为空，
`signs.place` 清空两个命名空间。之后每次保存都重复同一路径，直到 stamp 移动
或 buffer 被重新 attach。

子目录文件没有任何 fs 事件（根目录监听是非递归 liveness，`.svn` 监听只看
metadata），所以旧 view 永远不会被 retire；根目录文件的保存事件可能 retire
view，但 `BufWritePost` 与事件到达的先后顺序不稳定，于是表现为「偶尔」。

### 3.2 svn add 之后没有 BASE

`svn status --xml` 对已 `svn add` 未提交的文件返回 `item="added"`，
`SVN_ITEM.added` 标为 `tracked + worktree`，但该路径在 BASE 和 HEAD 中都不
存在。`load_base_show` 的 `svn cat -r BASE` 失败后重试 `-r HEAD` 也失败，
最终把 `st.base_text = nil`，`_render` 直接清空 sign。旧实现因此把「VCS 还
没有基线」误判成「没有可显示的内容」。

## 4. 修复

### 4.1 保存先告知 status view（D51）

`lua/vcssign/repo.lua` 新增 `Repo:note_save(path, tracked)`：

- view 命中且已有 tracked 条目：就地 `entry.worktree = true`；
- view 命中但路径缺席（clean）：若调用方说该路径 tracked，插入合成条目
  `{ tracked = true, staged = false, worktree = true }`；
- view 缺席但 status 查询在飞：`_drop_status()` 并返回 `deferred`，避免把
  保存前的答案缓存下来；调用方通过 `Repo:after_status` 等这次查询结束后再
  刷新（`lua/vcssign/attach.lua` 的 `M.note_written`）。

`BufWritePost` 改为：

```
BufWritePost → attach.note_written → repo:note_save → attach.refresh
```

`note_written` 在 metadata stamp 未移动且已有基线时只调用 `_render`，因此
普通保存不再起任何进程；第一次保存一个 clean 文件只多一次 BASE 读取（仍为
0 次仓库级 status）。

不选择「保存即 retire view」：那会让每次保存都跑一次仓库级 `status`，直接
违背 P0-1（每仓库一次 status）。也不选择无条件 `refresh`：它会重新落入旧
view 的 `from_buffer` 路径。合成条目只表达「可能 dirty」，真正的 hunk 仍由
基线读取决定。

### 4.2 svn added 使用空基线（D52）

- `lua/vcssign/vcs/base.lua` 的 `FileStatus` 增加 `added?: boolean`；
- `lua/vcssign/vcs/svn.lua` 的 `SVN_ITEM.added` 增加 `added = true`；
- `lua/vcssign/attach.lua:load_base_status` 在 ignored 分支之后、untracked
  分支之前处理 `entry.added`：`base_text = ''`，整文件按 add 渲染，不再调用
  `svn cat`；
- `reset_hunk` 对 `st.added` 明确拒绝（没有 BASE 可 patch），避免空基线让
  hunk 动作误以为可回退。

## 5. 测试

新增 4 个回归用例（全部在修复前失败）：

| 文件 | 用例 | 断言 |
|---|---|---|
| `test/repo_spec.lua` | a save of a clean file is folded into the view instead of retiring it | 合成 tracked/worktree 条目、同一张表、0 次 status |
| `test/repo_spec.lua` | a save during a status query waits for it and is not cached as clean | `note_save` 返回 `deferred`、在飞答案不缓存、随后查询得到 worktree |
| `test/autocmds_spec.lua` | a save keeps the signs of a clean file, against its real baseline | git 子目录文件真实 `:write`；`base_text` 仍是 `nested`，hunk 与 sign 保留 |
| `test/attach_spec.lua` | svn: a file scheduled for addition diffs against the empty baseline | `st.added`、`base_text == ''`、1 个 `add` hunk、2 个 sign |

## 6. 验证

```sh
sh scripts/make_test_repos.sh
sh scripts/run_tests.sh            # 330 tests, 0 failed
deps/luacheck.exe .
deps/stylua.exe --check $(git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua' 'plugin/*.lua')
git diff --check
```

手工复现按 §2 走一遍：保存后 sign 保留，`:Vcssign refresh` 不再清空，
`svn add new.txt` 显示整文件 add。

## 7. 影响与后续

- 第一次保存一个 clean 文件多一次 `show`（BASE 读取），仍然 0 次仓库级
  status；之后同一 buffer 的保存为 0 进程。
- 合成条目是保守的「可能 dirty」：一个内容未变的保存也会让下一次基线读取
  发生，直到 metadata stamp 移动；不会产生幻影 sign。
- D50 让被忽略路径在 view 中缺席；若某个被忽略文件在 attach 时被当作 clean
  tracked，保存会合成条目并触发两次注定失败的 `show`，可见结果仍是「无
  sign」（D49）。可选后续：首次保存缺席路径时按需 `is_tracked` 探测。
- 瞬时 `show` 失败（`E155004` 工作副本锁定、15 s 超时）仍会把 `base_text`
  置 nil；现在下一次保存会重新校正 view 并重试，但恢复仍依赖保存/刷新。
- `test/repo_spec.lua` 顶部关于「Repo 不再缓存 status view」的旧注释已同步
  改成当前实现（缓存 + D51 的保存折叠）。
