# 超大仓库打开文件卡死：仓库级 status 展开 ignored 路径（D50）

## 1. 症状

在超大工作树的仓库里打开一个普通文件，Neovim 主线程卡死数秒到数十秒；同一会话里
后续 buffer 命中 `Repo` 的 status 缓存后恢复。样例仓库：

```
/mnt/r5svault/luli/Documents/delite-library
```

文件总量 221,955，其中非 ignored 文件只有 570；仓库在 NFS4 上
（`r5svault.lan:/luli`，hard，512 KiB r/w）。

## 2. 测量

| 指标 | 值 |
|---|---|
| 文件总数 | 221,955 |
| 目录总数 | 4,207 |
| 非 ignored 文件 | 570 |
| ignored 文件 | 221,385 |
| 非 ignored 路径字节 | 25,016 B |
| 全部路径字节 | 16,880,169 B（约 16.1 MiB） |
| `.git/index` | 67.8 KiB（约 700 条） |
| pack 文件 | 1,138.3 MiB + 157.1 MiB + 0.66 MiB |

`git status --porcelain=v2 -z -uall --ignored=traditional` 实测输出 **222,738** 条 NUL
记录（ignored 文件 221,385 个，另含 ignored 目录记录），耗时约 1.73 s；
`--ignored=no` 输出 **0** 条（该仓库 570 个非 ignored 文件全部已跟踪且干净），
耗时约 0.22 s。

## 3. 根因

当前安装版本（7f50acc，M7）的 `lua/vcssign/vcs/git.lua: M.status` 运行：

```text
git status --porcelain=v2 -z --untracked-files=all --ignored=traditional --no-renames
```

`git-status(1)` 对 `--ignored=traditional` 的原文是：

> Show ignored files and directories, unless `--untracked-files=all` is
> specified, in which case individual files in ignored directories are
> displayed.

即 `-uall` 会让 traditional 模式展开 ignored 目录，而不是折叠。代码注释所依赖的
「traditional 会折叠 ignored 目录」在 `-uall` 下不成立。

第一次 attach 时 `Repo` 发起一次仓库级 status，`vim.system` 收集约 17 MB stdout，
随后 `M.parse_status` 在主循环里逐条执行：

```lua
entries[base.normalize(vim.fs.joinpath(root, path))] = status
```

`base.normalize` 对每条路径调用 `vim.fn.fnamemodify(..., ':p')` 与 `vim.fs.normalize`，
再建立 22 万条路径表；这是卡死的直接原因。`attach.status_entry` 在状态中找不到路径时
还会 `pairs(entries)` 做目录前缀扫描，进一步放大每次 attach 的成本。

已排除：

- `blame.lua` 已是逐行 `git blame -L l,l` + 逐行缓存（M7），不是整文件 blame；
- `vim.text.diff` / `signs.place` 受 `max_file_length` 限制，实测 40k 行 5.55 ms；
- fs 监听只监听 metadata + root（Linux 非递归）；
- root 检测只有一次异步 `git rev-parse`。

## 4. 修复

- **D50**：仓库级 status 不再请求 ignored 路径。git 使用 `--ignored=no`，svn 去掉
  `--no-ignore`。被忽略路径在 status view 中缺席，`load_base_status` 把缺席路径当作
  clean（`base_text` = 缓冲区文本），因此仍然不画 sign，D49 的用户可见行为不变。
  `FileStatus.ignored` 的解析分支保留给适配器与测试；未来若某动作需要该信息，按需
  调用 `git check-ignore -q -- <rel>`，不要放进 attach 路径。
- **`max_status_bytes`**（默认 4 MiB，0 关闭）：在 `parse_status` 之前检查
  `#res.stdout` 并返回 `status output too large: N bytes (limit M)`。`Repo` 按
  baseline stamp 缓存这个确定性错误，超限时回落到逐文件 `is_tracked`/`show`；
  `_drop_status` 在 index/HEAD/refs 变化时清掉缓存，仓库缩小后可以恢复捷径。
- `status_entry` 的目录前缀扫描保留（svn 仍可能报告目录），但 git 的 `-uall`
  不再产生 ignored 目录记录，常见路径恢复为精确键查找。

## 5. 测试

- `test/vcs_git_spec.lua`：stub `exec.run`，断言 status argv 含 `--ignored=no` 且不含
  `--ignored=traditional`；超限 stdout 在解析前被拒绝。
- `test/vcs_svn_spec.lua`：断言 `svn status` argv 不含 `--no-ignore`。
- `test/attach_spec.lua`：ignored 文件不再有 `st.ignored`，但 `base_text` 为缓冲区文本、
  hunk 数为 0、sign 数为 0；ignored 文件只花 `rev-parse` + `status`，不读 baseline。
- `test/repo_spec.lua`：超限错误按 stamp 缓存，第二次查询不重新 spawn；`_drop_status`
  后重新查询。
- `test/config_spec.lua`：`max_status_bytes` 默认 4 MiB，可设为 0。
- `test/doc_spec.lua`：`vcssign-config-max_status_bytes` 已写入帮助文档。

## 6. 验证

```bash
cd /mnt/r5svault/luli/Documents/delite-library

# 旧命令：222,738 条记录（约 1.7 s）
time git --no-optional-locks status --porcelain=v2 -z \
  --untracked-files=all --ignored=traditional --no-renames \
  | tr -cd '\0' | wc -c

# 新命令：0 条记录（该仓库工作树干净，570 个非 ignored 文件全部已跟踪）
time git --no-optional-locks status --porcelain=v2 -z \
  --untracked-files=all --ignored=no --no-renames \
  | tr -cd '\0' | wc -c

# 新命令中不应再有 `!` 记录
git --no-optional-locks status --porcelain=v2 -z \
  --untracked-files=all --ignored=no --no-renames \
  | tr '\0' '\n' | grep -c '^!'
```

随后在最小配置下打开仓库中的非 ignored 文本文件，确认不再出现主线程长时间无响应；
打开 ignored 文件确认无 sign；把 `max_status_bytes` 临时设为 1，确认回落到逐文件查询
且 sign 正确。

实测（headless，`current_line_blame = false`）：

- `light-novel/library.json`：attach 完成 181 ms，hunk 0、sign 0；
- ignored 的 `manga/みゆちゃんはずっと友達/cover.avif`：94 ms，按缺席（clean）处理，
  hunk 0、sign 0。

完整测试（svn 1.14.5 已安装）：`make test` → **323 tests, 0 failed**，包含
`actions_spec`、`cli_spec`、`proc_budget_spec` 及新增的 svn argv 测试。
`make lint`、`make format-check` 均通过。

## 7. 未做/后续

- `status_entry` 的目录扫描优化（无 dir 记录时跳过 `pairs`）；
- `--untracked-files=normal` / 自动 status view：可减少大量 untracked 目录的展开，
  但 per-file ignore 规则仍可能产生大量记录，作为 P2；
- `exec.stream` 在累计字节超限时立即 kill 子进程（当前是收集完再拒绝）；
- `repo_manager.attach` 的同步 `registry.detect` 缓存，减少 NFS 上的向上 stat；
- 按需 `git check-ignore`，只在未来动作确实需要 ignored 标志时使用。
