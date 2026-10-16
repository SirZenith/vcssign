# backlog：行级 sign 与 diff（`signs/`）

**状态**：`[ ] 未开始`

**出处**：`loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §10（全部 8 项）
与 §11 的第 1、3、4 项（待验证项）。

**为什么记下来**：M6 把插件从「文件级状态侧边栏」转向「行级 hunk sign」时，这些是**明确决定
不做**或**当时测不出来**的事情。不做的理由都成立，但一旦用户点名、或遇到边角场景，就直接从
这里接手，不必重新踩一遍。

---

## 一、backlog（明确不做，但记下来）

> 原文（`07 §10`），逐条保留：

1. `diff.use_external` 外部 diff 回退（D39 的 opt-in 位，处理内置 diff 与 `git diff` 行为不一致的边角）。
2. `max_diff_lines`（hunk 数上限，与 `max_file_length` 互补）。
3. `diffthis [rev]` 的 rev 列表补全（`git log --pretty=%h` / `svn log`）。
4. **内存内 patch 应用**（即使缓冲区有未保存改动也能 reset，gitsigns 用 text edit 同步）。
5. `:Vcssign setqflist`（把 hunk 灌进 quickfix）。
6. **svn hunk 级丢弃的替代方案**（当前依赖反向补丁 + `svn patch --strip 0` 临时文件）。
7. **`patch_of` 的基线新鲜度**（审查 F5）：动作读的是 `st.base_text`（上一次探测拿到的 index 内容）。
   磁盘被别的程序改过时补丁会对不上，表现是 git 报 `patch does not apply` —— 安全但不友好。在动作前
   做「磁盘 vs 缓冲区」的比对会在 CRLF / `autocrlf` 上有假阳性，所以留到能同时处理行尾时再做。
8. **`guarded(fn)` 的复制**（审查 F9）：11 份 spec 各自抄了一份清场包装，该收进 `test/helpers.lua`。

### 逐条验收要点

| # | 验收要点 |
|---|---|
| 1 | 新增配置 `diff.use_external`，默认 `false`；开启时走外部 `git diff`，并对内置 diff 的已知差异（见 `loop/knowledge/nvim/diff-and-hunks.md`）逐个用例覆盖 |
| 2 | 与 `max_file_length` 同样在探测阶段短路；超限时**静默**不放置 sign（不报错），且提示只发一次 |
| 3 | rev 补全用 `-complete=customlist`；git 侧 `git log --pretty=%h`、svn 侧 `svn log`；svn 不可用时退化成空集 |
| 4 | reset/apply 不再要求「无未保存改动」；改缓冲区文本走 `nvim_buf_set_lines`，且 `EOL` / CRLF 行为有专门用例 |
| 5 | `:Vcssign setqflist` 把当前缓冲区的 hunk 写进 quickfix，条目带行号与类型；空 hunk 时给出明确提示 |
| 6 | 给出 svn 侧不依赖临时文件的路径，或明确记录「做不到」并保持能力门（`VcsCaps`）不变 |
| 7 | 动作前做「磁盘 vs 缓冲区」比对；`core.autocrlf` / CRLF 场景无假阳性（需先解决行尾归一） |
| 8 | `guarded(fn)` 收进 `test/helpers.lua`，11 份 spec 的本地副本删除；`make test` 全绿 |

第 8 项是纯测试重构，可以独立做、先做。

## 二、待验证项（探针报告标为「不确定 / 需要再测」）

> 原文（`07 §11`）第 1、3、4 项。第 2 项（`svn patch --strip` 语义）的事实已并入
> `loop/knowledge/vcs/svn-output-formats.md`；第 5 项（`svn blame` 大文件耗时）在
> `loop/workspace/testing/2026-10-16T23-59-34-backlog-ci-and-test-hygiene.md`。

1. **`on_reload` 与 `:e!` 的差异**：仅在 Windows/nvim 0.12.4 组合实测 `:e!`→`on_detach`；不同平台/版本可能不同，
   实现里两种都兜底（`on_detach` + `BufReadPost`）。
3. **`git blame` 行号对齐在「hunk 含多行（`num_lines > 1`）」时未专门验证**，只验证了每组 1 行。
4. **`yes:2` 下「两个 sign + 开启 number」时第二个 sign 的显示未稳定复现**（负优先级 sign 是否显示未定论）。

### 逐条验收要点

| # | 验收要点 |
|---|---|
| 1 | 在 Linux（本机）与另一平台/版本组合上实测 `:e!` 触发哪个回调；结论写回知识文档或本任务文档，实现保持双兜底 |
| 3 | 加一条 `blame_spec` 用例：hunk 含多行时逐行 blame 行号与 sign 对齐 |
| 4 | 在 `yes:2` + `number` 下稳定复现第二个 sign 的显示与否，得出「负优先级 sign 是否显示」的结论并补用例 |
