# 06 · 总实施 TODO 清单

> 本文是 `impl/init/` 系列的**执行总索引**：把 01–05 各计划文件的实现步骤
> 汇总为一份可勾选的总清单。每项标注出处（计划文件 §节）。
> 状态标记：`[ ]` 未开始 / `[~]` 进行中 / `[x]` 完成。

## M0 · 环境与 fixture 准备（05 §0、§2）

- [x] `.gitignore` 追加 `/temp/`、`deps/`、`.nvimlog`（用户已完成，实测生效）
- [x] `temp/` 目录就位（用户已手动创建）
- [x] 环境确认：git 2.55.0.windows.2、svn 1.14.5（≥1.9，`--show-item wc-root` 实测可用，svnadmin 实测可用）
- [x] `temp/git-repo`：状态矩阵（local M / local D / `??` 含空格+中文路径 / upstream A / upstream M+local M / upstream R rename）—— 05 §2.1，实测见附录 A1
- [x] `temp/git-repo-conflict`：merge 冲突（`UU conflict.txt`）—— 05 §2.1，实测见附录 A1
- [x] `temp/git-worktree`：`git worktree add` 成功；`git rev-parse --show-toplevel` 返回 `D:/...` 正斜杠路径（实现需 `vim.fs.normalize`，但无需格式转换）—— 05 §2.1
- [x] `temp/svn-server` + `temp/svn-repo`：file:// checkout（`file:///D:/...` 三斜杠+盘符实测有效）；状态矩阵 `MM / ! / ? / D / A / R` 全部命中—— 05 §2.2，实测见附录 A2
- [x] `temp/nested`：git 仓库（`inner/` 已 ignore）内嵌 svn checkout；`svn info --show-item wc-root` 对两处 wc 均返回正确 root —— 05 §2.3
- [x] `temp/svn-conflict-a` + `temp/svn-conflict-b`：**真实 tree conflict**（列 7 C + `>` 续行 + `Summary of conflicts:` 尾行）—— 05 §2.3
- [x] `temp/svn-switch`：**真实 switched 子目录**（列 5 S）—— 05 §2.4
- [x] 实测捕获：见附录 A1/A2/A3

## M1 · VCS 抽象层（01，P0）—— ✅ 已完成（53/53 spec 通过）

- [x] `lua/vcssign/status_type.lua`：统一状态枚举 + 默认符号/高亮/优先级三件套（01 §2）
      兼 `camel/symbol/sign_hl_group/hl_group/sign_priority` 查询函式
- [x] `lua/vcssign/vcs/base.lua`：`VcsSystem` 接口 + emmylua 元类型 + `unsupported()` 能力兼底
      兼共享工具 `normalize/dirname_of/abspath/relpath/find_root_upwards/make_entry`（01 §3）
- [x] `lua/vcssign/vcs/git.lua`：
  - [x] root：`rev-parse --show-toplevel`（异步权威）+ `.git` 目录/文件同步兜底（01 §4.1）
  - [x] status：`--porcelain=v1 -z --untracked-files=all`，NUL 解析 + rename 双段消费（01 §4.2）
  - [x] stage/unstage/commit/diff 命令（unstage 自动回退 `reset HEAD --`）（01 §4.3）
- [x] `lua/vcssign/vcs/svn.lua`：
  - [x] root：`svn info --show-item wc-root` + `.svn` 同步兜底 + `<1.9` 懒降级 warn（01 §5.1）
  - [x] status：固定列解析（第 9 列起）+ 列7 tree conflict/列2 属性修改/续行跳过（01 §5.2）
  - [x] capabilities：`stage=false`，commit/diff 命令（01 §5.3）
- [x] `lua/vcssign/vcs/init.lua`：registry + `detect`/`detect_async`，嵌套仓库取更深 root（01 §6）
- [x] **额外前置（原属 M2，因适配器依赖而提前）**：`lua/vcssign/exec.lua`（`vim.system` 封装）、
      `lua/vcssign/config.lua`（最小配置 + `merge`）
- [x] 验收：01 §7.1–7.5 全部覆盖（`test/vcs_git_spec.lua` + `test/vcs_svn_spec.lua` +
      `test/vcs_registry_spec.lua` + `status_type_spec` + `config_spec` = **53 用例，全绿**）
- [x] 代码审查（独立 code-reviewer 两轮）发现的问题已修复—— 见本文件附录 B

## M2 · 仓库运行时（02，P1）—— ✅ 已完成（81/81 spec 通过；含二轮回归 3 例）

- [x] `lua/vcssign/exec.lua`：`vim.system` 封装 + `LC_ALL=C`、MSYS noglob、超时、`split_nul/split_lines`（02 §2）
      **已在 M1 落地**（适配器依赖）；`pcall` 包住 `vim.system`（命令不存在时会抛 ENOENT 而非回调，已实测）
      + **M2 审查后修正：回调统一切回主循环**（`vim.system` 的退出回调本身就在 fast-event，实测）
- [x] `lua/vcssign/log.lua`：分级日志（debug/info/warn/error），全部 `vim.schedule` → `vim.notify`
      （uv 回调是 fast-event 上下文，直调 vim API 会报 E5560 —— 已实测）
- [x] `lua/vcssign/util.lua`：`is_dir` / `subscribe` / `emit`（监听器异常隔离）
- [x] `lua/vcssign/debounce.lua`：移植 gitsigns `debounce_trailing`（MIT 注明）+ `cancel()` + `vim.schedule` 修正（02 §6.5）
- [x] `lua/vcssign/repo.lua`：
  - [x] 状态缓存 `status/status_map` + `get_entry/get_status/entries`（02 §3.1；路径键 Windows 大小写折叠）
  - [x] fs 监听：root + 直接子目录（非递归）+ **`metadata_path`**（非 Linux 递归；worktree 的 gitdir 由 `metadata_dir` 解析），句柄池化，回调只置脏（02 §3.2）
  - [x] 刷新管线：防抖 + 防重入补跑 + map 剪裁（首轮必通知）+ 失败指数退避（02 §3.3）
  - [x] `system.status` 调用本身 `pcall` + `done` 幂等闸（适配器抛异常不卡死管线）
  - [x] 完成回调先查 `is_deleted`（命令飞行中被 dispose → 不产生任何副作用）
  - [x] `dispose` 统一清理（句柄 stop+close，去抖/退避 timer 关闭，**在排 waiter 带 reason 释放**）
- [x] `lua/vcssign/repo_manager.lua`：`attach(ref, path, cb)` / `detach(ref)` 引用计数、缓存快速路径、
      `active/get_by_path`、`on_repo_attached/detached`、`dispose_all`（02 §4）
      + **per-ref 世代号**防 attach↔detach 竞态泄漏引用
- [x] 验收：02 §5.1–5.5 + §4，共 **18 个用例**（`test/repo_spec.lua`），含 `vim.uv.walk` 句柄清零断言
      —— 实测数据见本文件附录 C，审查修复见附录 D

## M3 · 侧边栏 UI（03，P2）—— ✅ 已完成（114/114 spec 通过，含审查修复）

- [x] `lua/vcssign/config.lua`：`sidebar` 段（`position`/`width`/`group_by`/`keymaps`）（03 §2、§5）
- [x] `lua/vcssign/sidebar/init.lua`：窗口/缓冲区生命周期（open/close/toggle/focus/close_all/forget_all、
      `nvim_open_win{split}`、`signcolumn=yes:2`、订阅跟缓冲区走、`VimResized` 重画、`cursor_entry`）（03 §2）
- [x] `lua/vcssign/sidebar/renderer.lua`：
  - [x] 排序（严重度→字典序）+ 分组（git 三组，svn 无 index 域则扁平）（03 §3.1）
  - [x] 双 extmark sign 位渲染（`+1000` upstream 偏移 → porcelain XY）+ namespace 全量重画（03 §3.3）
  - [x] 高亮组定义（`default = true`，18 组，覆盖枚举全部取值）（03 §3.4）
  - [x] `item_at`/`entry_at` 行模型反查（0 基行号，缓存于 `vim.b[bufnr].vcssign_items`）（03 §4）
  - [x] `banner` 三态占位（refreshing / 失败原因 / no changes）（03 §7.1 #6）
- [x] `lua/vcssign/sidebar/keymap.lua`：默认 8 键（`<cr> t d s u r q ?`）+ `dispatch()` 单一分派入口
      + capability 门控（svn 提示 `no staging area`，INFO）+ 动作交 04（M3 期缺模块则明确提示）（03 §5）
- [x] 光标行恢复：按 rel_path 恢复（行号只作兜底）（03 §3.5）
- [x] 验收：03 §6.1–6.6 全部通过（表格见 03 §6，`sidebar_spec` 用 `screenstring` 读真实屏幕断言）
- [x] spec：`renderer_spec`（15，纯函数）+ `sidebar_spec`（18，真实仓库/窗口/按键）
- [ ] backlog（明确不做）：`position = "float"`、`single_column`、`group_by = "directory"` 树模式、
      条目级增量更新（1000 行 7ms，全量重画足够）—见 03 §7.3

## M4 · 命令与动作（04，P3）—— ✅ 已完成（167/167 spec 通过，含独立审查修复）

- [x] `lua/vcssign/actions.lua`：open/diff/stage/unstage/commit/refresh，动作后强制 refresh（04 §2）
- [x] diff 展示：unified diff → nofile 缓冲区 `filetype=diff`，同文件复用缓冲/窗口，只读（04 §2.1）
- [x] `lua/vcssign/cli.lua` + `plugin/vcssign.vim`：`:Vcssign` 子命令族（+`diff`/`debug`）+ customlist 补全（04 §3）
- [x] `lua/vcssign/autocmds.lua`：BufReadPost/BufEnter/BufDelete/DirChanged/FocusGained/VimLeavePre（04 §4）
- [x] 公共 API：`setup/open/close/toggle/refresh/get_status/get_entries` + `M.cli`（04 §5）
- [x] 验收：04 §6 全部 8 条（含两条额外的：空会话第一条命令可用、`plugin/` 薄壳真的注册了命令）
- [x] 测试：`actions_spec` 24 + `cli_spec` 17 + `autocmds_spec` 10 + `exec_spec` 9（05 §6）

M4 期间修掉的三个既有缺陷（都在 04 §7.1 有完整记录）：
1. `exec.run` 的超时定时器武装顺序 → 立刻失败的进程会留下一个**已武装**的定时器（15s 后才自我关闭）。
2. `repo_manager.ensure`（新）与 `get_by_path` 的语义差：嵌套仓库时内层文件会被判给已 attach 的外层仓库。
3. 路径未解析就传给 `ensure` → `base.normalize(nil)` 静默变成「cwd 下的相对路径」（实测字符串 `v:/null`）。

## M5 · 测试与工程化（05，P4，M1 起并行）—— ✅ 完成（174/174；CI 仍 backlog）

- [x] `scripts/make_test_repos.sh`：幂等生成全部 fixture（已实测：从零重建 + 连续两次跑均正确）（05 §2）
- [x] `scripts/run_tests.sh` + `test/run.lua` + `test/helpers.lua`：TAP 输出、exit code、svn 缺失 SKIP、
      `helpers.wait` 阻塞式异步测试（取代计划里的 `preload.lua` + `wait_for`）（05 §3）
- [x] spec（M1 部分）：`status_type_spec` / `config_spec` / `vcs_git_spec` / `vcs_svn_spec` / `vcs_registry_spec`（53 用例）
- [x] spec（M2 部分）：`repo_spec`（21 用例）+ `exec_spec`（7 用例，固化「回调在主循环」契约）
- [x] `test/helpers.lua` 扩展：`scratch_dir` + `cleanup`（末尾清理）、`git_repo` / `svn_checkout` / `git_worktree`
      （**可变的临时仓库**，不碰 M1 断言依赖的共享 fixture）、`sh` / `write` / `wait_for` / `uv_count` / `with_repo`、
      `capture_notify`（含 `vim.schedule` 排空，否则 `log` 的 warn 会绕过桩）、`screen_line` / `screen_line_at`（读屏幕单元格）
- [x] spec（M3 部分）：`renderer_spec`（15 用例，纯函数）+ `sidebar_spec`（18 用例，真实仓库/窗口/按键）
- [x] spec（后续里程碑）：`actions_spec`（24 用例，M4；在副本仓库上跑真实 stage/unstage/commit 并用 VCS 自身核对）
- [x] `stylua.toml` / `.luacheckrc` / `Makefile`（help/tools/fixtures/test/format/format-check/lint）+ `scripts/tools.sh`
      （钉版本 stylua 2.3.1 / luacheck 1.2.0 到 `deps/`）；`format-check` 零输出、`lint` 0 警告（05 §4）
- [x] `doc/vcssign.txt` 初版手写（8 节 254 行）+ `test/doc_spec.lua`（7 用例：配置键 / 子命令 / 状态 / 高亮 /
      键位动作 / API / `:helptags` tag 唯一）（05 §5）
- [ ] CI（backlog，**未做**）：ubuntu+windows matrix——本机无 GitHub 远端，写了也无法验证；接入步骤见 05 §4

## M6 · 行级 sign（07，P0 转向）—— 🚧 进行中（Step 1–5/14 完成，178/178）

> 用户要求把「文件状态侧边栏」换成 gitsigns 式的**行级 sign**（状态直接进 `'signcolumn'`）。
> 设计、探针实测与分步计划见 `07-signs-in-signcolumn.md`；**交接说明见该文 §6.1–§6.4**
> （已落地 SHA 表 + 回归始末、每步工作契约、已知坑、Step 6 入口）。

- [x] **Step 1** 退役侧边栏，留最小 sign 骨架 —— `080379c`（174 → 125，全绿）
- [x] **Step 2** `Repo` 降级为元数据会话 + `exec` 支持 `stdin` —— `3ecbdd7`（128 用例；**本步引入回归**：只监听 metadata 后工作副本被删不再被发现）
- [x] **Step 3** `hunk.lua` + `diff.lua`（`vim.text.diff` 封装）—— `5e8e485`（125 → 158）
- [x] **Step 4** 适配器换血：`show` / `is_tracked` / `blame` / `apply_patch` / `revert`，`VcsCaps` 换字段 —— `7acc713`（150）
- [x] **Step 5** `signs.lua`（双命名空间 + 放置规则 + 高亮）+ `attach.lua`（守卫 / 基线 / diff / 渲染 / `nvim_buf_attach`）—— `6eaef2b`（150 → 178）
- [x] 顺带修掉两条独立缺陷：`f1d1735`（`fix(repo)` 根目录加非递归 watch，修 Step 2 的回归；`FILTER=repo_spec` 由 2/20 红 → 连跑两次 20/20 绿）、`e6c4f1b`（`fix(vcs)` svn 追踪判定改用 `svn info`，并更正 07 §3.1 / §5.3 的两处探针结论）
- [x] 文档：`9b4eb90`（07 设计与探针实测）+ §6.1–§6.4 交接
- [ ] **Step 6** 刷新触发（`on_lines` 防抖 / `on_reload` / `repo:on_update`）+ 生命周期 autocmd + 开关
- [ ] **Step 7** git 暂存态双层 sign
- [ ] **Step 8** `nav.lua`（`]c` / `[c`）+ `keymap.lua`
- [ ] **Step 9** hunk 级动作 + CLI
- [ ] **Step 10** `worddiff.lua` + `preview.lua`
- [ ] **Step 11** `blame.lua` + `revdiff.lua`
- [ ] **Step 12** 文档与帮助回写（`00`–`06`、`doc/vcssign.txt`、`doc_spec`）
- [ ] **Step 13** 独立审查（`code-reviewer` 审 M6 起点..HEAD）+ 修复
- [ ] **Step 14** 终验（全量两遍幂等、stderr 合同、`git diff --check`、逐 SHA 复跑）

**工程门（`6eaef2b` 实测）**：`make test` → `178 tests, 0 failed`；`make format-check` → 零输出；
`make lint` → `Total: 0 warnings / 0 errors in 35 files`。stderr 行数在 **0/1** 之间浮动
（retry 用例的 1ms 超时告警，不参与断言）—— Step 14 定论。

## 里程碑依赖

```
M0 ─→ M1 ─→ M2 ─→ M3 ─→ M4
       │
       └───→ M5（fixture/spec 随 M1/M2/M3 同步落地）
```

## 附录 · 实测记录（2025-… 本会话，Windows / git 2.55.0.windows.2 / svn 1.14.5）

### A1 · git `status --porcelain=v1 -z --untracked-files=all`（`temp/git-repo`）

NUL 分隔（下文以换行代替 NUL 展示；中文路径按 UTF-8 原样传输，无需引号解码）：

```
 M base.txt
 D old.txt
 R  renamed.txt
 文件 名.txt          ← rename 条目的第二段（orig_path），紧跟新路径段之后，整体消费
 A  staged-add.txt
 AM staged-mod.txt
 ?? new.txt
 ?? untracked 名 .txt
```

要点确认：
- rename 记录是**连续两段**（新路径 + orig_path），解析循环必须按 01 §4.2 的「双段消费」处理；
- `core.quotepath` 引号转义**不会出现**在 `-z` 输出中（计划 D3 验证成立）；
- 状态域实际形态：` M`（local M）、` D`（local D）、`R `（upstream R）、`A `、`AM`（upstream A + local M）、`??`（untracked）。

冲突仓库 `temp/git-repo-conflict`：`UU conflict.txt`（upstream U + local U → conflicted）。

`git rev-parse --show-toplevel`（`temp/git-worktree`）输出：`D:/Developer/nvim-plugins/vcssign/temp/git-worktree` —— 正斜杠绝对路径，直接可作 root 键（统一 `vim.fs.normalize`）。

### A2 · `svn status`（`temp/svn-repo`）

```
MM      base.txt
!       missing.txt
?       new.txt
D       old.txt
A       prop.txt
R       repl.txt
```

要点确认：
- `MM` = 第 1 列 M（内容修改）+ 第 2 列 M（属性修改）—— 01 §5.2 的「列 1 主状态 + 列 2 属性补充」策略成立；
- `!`（missing）、`R`（replaced，`svn rm --keep-local` + `svn add` 制得）按预期出现；
- `svn info --show-item wc-root` 对 `svn-repo` 与 `nested/inner` 都返回正确绝对路径（svn ≥ 1.9 特性可用，D4 成立）；
- file:// 仓库 URL 形态：`file:///D:/Developer/.../temp/svn-server/trunk`（三斜杠 + 盘符，`pwd -W` 可直接生成）。
- **补充（M1 阶段）**：两处输出均为 **CRLF** 行尾；svn 路径用**反斜杠**且从**第 9 列**开始（`sub2\q.txt`、目录条目 `sub2` 与文件条目 `sub2/q.txt` 都出现）。

### A3 · 其他实测结论（M1 阶段）

| 结论 | 含义 |
|------|------|
| `vim.system` 在命令不存在时 **抛异常**（`ENOENT`）而非回调 | `exec.run` 必须 `pcall` 包住，否则插件会把错误抛到调用栈上 |
| `t.local = 1` / `status.local` 是**语法错误** | 状态字段改名 `index` / `worktree`（D11） |
| `vim.fs.normalize` 是**词法**归一化，**不补绝对路径** | 相对入口（`-l test/run.lua`）必须 `fnamemodify(p, ':p')` 后再 `normalize` |
| `vim.fs.normalize(fnamemodify(p, ':p'))` 在 Windows 上 = 反斜杠→正斜杠 + 去尾分隔符 | 路径归一化无需手写处理 |
| `svn status <target>` 打印**相对 cwd** 的路径 | 必须 `cwd = root` 且不传 target（D5 的 vcs-helper 缺陷根因） |
| `svn add --force` 幂等（已版本化=无操作，已调度删除=变 R） | 不要用 `svn info` 做「是否已加入」守卫（会把 R 症状变成 D） |
| `svn add dir/file.txt` 需 `--parents` | 否则 `E200009` |
| 带冲突的工作副本末行会输出 `Summary of conflicts:` / `  Tree conflicts: 1` | 无冲突时不会有这两行；解析器必须「不认识的列字符即丢弃」而不是白名单匹配 |
| `git notacommand` 的错误文案是 `git: 'x' is not a git command.` | 旧版 git 的 `restore` 走的是这条，而不是 `unknown option` |

## 附录 B · M1 代码审查与修复（独立 code-reviewer 两轮）

审查结论：无阻断性问题，主链路（root 检测、`-z` 双段解析、svn 固定列、状态归一化、回调唯一性）经
静态核对 + Neovim runtime 源码交叉验证均正确。以下问题已全部修复并重跑 53 用例全绿：

| 级别 | 问题 | 修复 |
|------|------|------|
| major | `unstage` 的旧版 git 回退是**死代码**（只匹配 `unknown option`，而旧版 git 报的是 `not a git command`） | 两个文案都匹配（小写归一） |
| major | `detect_async` 无条件用 marker 结果兼底，会把 stale marker 复活成**幽灵仓库** | marker 必须真像仓库（`.git/HEAD` 存在 / `gitdir:` 目标存在）；另加「确定性否定」黑名单（`not a git repository` / `not a working copy` / `E155007`） |
| major（测试） | 「marker 扫描不可见」的回落分支用例**根本没走到回落**（`svn-repo/sub2` 上层就有 `.svn`） | 重写为 stub 模块用例，真正走 `step()` 循环（成功/全失败/最后错误透传三个用例） |
| major（测试） | svn 列 7/列 5/列 2 只有**自证式**单元用例（与解析器共享列宽假设） | 新增两个**真实** fixture：tree conflict（列 7）、switched（列 5）+ 真实空格/中文路径 |
| minor | `vim.fs.normalize` 默认展开 `$VAR`，会改写含 `$HOME` 这类片段的真实路径 | `{ expand_env = false }` |
| minor | `relpath` 对「仓库就是文件系统根 `D:/`」必然返回 nil（`normalize('D:/')` 保留尾分隔符，实测） | 前缀拼尾分隔符后再比长度 |
| minor | svn 无反斜杠→正斜杠的**平台判定**，POSIX 上会改写合法文件名 `a\b.txt` | 仅 Windows 转换（用 `exec.is_windows`） |
| minor | `split_lines` 只处理成对 CRLF，末行孤立 `\r` 会进路径 | 逐行去 `\r$` |
| minor | `git.commit` 空文件列表会 `git commit -m msg --` → **提交整个索引** | 空列表直接报错；svn 同理 |
| minor | git 的双段消费条件包含 `y == 'R'/'C'`（porcelain v1 的 Y 列不存在 R/C） | 只看 X 列 |
| minor | `svn.commit` 返回的 `info` 是进度行 `Sending   x` 而非提交摘要 | 优先匹配 `Committed revision N` |
| minor | `abspath` 每条目一次 `fnamemodify(':p')`（万级文件仓库开销可见） | 只用 `vim.fs.normalize(joinpath)`（root 已是绝对路径） |
| minor | `config.merge` 嵌套层 list 会按下标合并；`vim.islist({})==true` 使 `{sidebar={}}` 整体替换 | 递归 merge + `is_dict` 判定（空表按 dict 处理） |
| minor | svn 列 5 `X`（file external）未映射，条目被整条丢弃 | 补映射为 `external` |
| minor（测试） | 全局单例（config / `registry.MODULES`）在断言失败时不恢复；`REQUIRES` 未覆盖 git；临时目录不清理 | `with_isolated_state` + `pcall`；`REQUIRES` 改为多值；临时目录用完删 |

未修复（已知且已在 05 §3 标注为未覆盖）：svn `<1.9` 降级、git `unstage` 旧版分支（需 git < 2.23，
本机无法制造，仅对错误文案做了实测）、`exec` 的超时/spawn 失败用例。

审查提出的**契约级提醒**已写入设计文档：同步回调（能力不支持 / 空参数）会让 M2 的
「调用后置标志」写法打穿，见 01 §3 的说明。

## 附录 C · M2 实测记录（Windows 11 · nvim 0.12.4 · git 2.55 · svn 1.14.5）

全部为探针脚本在本机的**直接观测**，非推断：

| 观测 | 数值/结果 | 影响 |
|------|-----------|------|
| `uv_timer_t` / `uv_fs_event_t` 回调是否 fast-event | **都是 `vim.in_fast_event() == true`** | 所有 uv 回调必须 `vim.schedule_wrap`；否则 `vim.fn.writefile` 直接报 `E5560` |
| 单文件改内容 | root 非递归监听收到 `change=true, filename=base.txt` | 只监听 root 就能发现 root 层文件编辑 |
| `git add` 的 fs 事件量 | `.git` 递归监听收到 ~12 个事件（`index.lock` → `index` rename 等） | 去抖不是优化而是必需；这也是 §5.2 那条「≤2 轮」的由来 |
| `h:start(不存在的目录, {}, cb)` | 返回 `nil, ENOENT` | `_watch` 必须先 `fs_stat` 判目录 |
| 删除/改名**被监听目录**后 | libuv **持续投递**事件（探针刷出上千条、nvim 卡住不退出） | 首个事件必须 `_mark_deleted()` → `stop()+close()`；实测 `stop()` 后 400ms/800ms 事件数不再增长 |
| Windows 上 rename 被监听的目录 | `uv.fs_rename` 成功（即使句柄开着） | §5.4 的「marker 消失」用 rename 实现（删目录有风险） |
| `git status` 是否回写 `.git/index` | 用了 `--no-optional-locks` 后 **mtime 不变** | 不存在「自己触发自己」的自激刷新环 |
| `git add` 后的 `svn`/`git` 域 | `M `（index=modified, worktree=nil） | 只能通过 `.git` 监听发现 |
| 全新 `svn co` 出来的 wc | `svn status` **为空**（fixture 的脏状态只存在于工作副本，不在服务端） | repo_spec 的 svn 用例改为「建仓后自己制造变更」 |
| `exec.run` 计数验证 | 10 次快写 → **1 轮** `git status`（断言 ≤2） | 去抖+串行补跑生效 |
| 句柄清零 | `dispose_all()` 后 `uv_count('fs_event')` 与 `uv_count('timer')` 均回到基线 | 无句柄泄漏 |
| 全量套件 | **67 用例，0 失败，11s**；连跑两次同结果；共享 fixture 矩阵未变 | 幂等可复现 |

四个复用价值高的探针结论（已进代码注释）：
1. `vim.schedule_wrap` 是所有 uv 回调的硬要求（不是「保险」）。
2. **停止监听必须在第一个「仓库消失」事件里完成**，否则事件风暴。
3. 撤消/收敛类断言要等 `deep_equal` 剪裁后的**第二次** `on_update`。
4. `dispose` 清空在排 waiter 而不回调 → 调用方永久挂起（探针复现 `waiter called=false`）；
   已修为带 reason 释放（`_mark_deleted` 先 flush 再广播 `on_delete`）。

## 附录 D · M2 独立代码审查（code-reviewer）与修复

审查给出 1 critical + 3 major + 6 minor + 测试/文档问题；逐条定论与动作见 `02-repo-runtime.md` §7。
最值得记住的三条：

1. **critical（已修）**：`repo_manager` 的检测是异步的，`attach` 与 `detach` 竞态时
   晚到的回调会把**已释放的引用**重新绑定 → 仓库与它的监听永久存活。
   修法：每 ref 一个**世代号**，`detach` 递增；回调世代不符就拒绝绑定并回调
   `attach cancelled: ...`。（`BufEnter` + 立刻切 buffer 就能触发。）
2. **major（已修，影响 M3/M4）**：`exec.run` 的回调在 **fast-event 上下文**（`vim.system`
   本身如此，不只超时路径）。在那里 `vim.notify` / `nvim_buf_set_lines` 会报 E5560，
   也就是说 **M3 的渲染器回调会被 pcall 静默吃掉**。修法：在 `exec.run` 的 `finish` 里
   统一 `vim.schedule`，把「回调在主循环」变成全局契约，并加 `exec_spec` 用例钉住。
3. **major（已修）**：git worktree / submodule 的 `.git` 是**文件**且真 index 在仓库外，
   原来的监听集完全看不到 `git add`。修法：新增适配器钩子 `system.metadata_dir(root)`，
   监听 `metadata_path`；用例在 worktree 里做 `git add`。

另外两个「自己没想到、被审查抓到」的（都已修）：命令飞行中被 dispose 还会在已终结对象上
建退避 timer；Windows 大小写折叠只做了 `relpath` 没做 map 键（会为同一仓库建两个 Repo）。
审查中**经核实不成立**的一条：`dispose()` 并非不通知 manager —— `_mark_deleted` 会 emit
`on_delete`，manager 正是靠它 `_remove`（已写进文档注释）。

顺带修了测试基建的一个真问题：headless 下 `print` 走 **stderr**，会和插件的 `vim.notify`
日志粘成一行（实测把两条 TAP 行拼在一起），现在结果显式写 stdout。

## 附录 E · M2 收尾后的第二轮全量审查

code-reviewer 复查全部实现（~2400 行）：**无 critical，2 major + 7 minor**，逐条定论见
`02-repo-runtime.md` §7「第二轮」。三条最值得记住的：

1. **major（已修，实证）**：`relpath(root, root) == nil` —— 前缀（根 + 分隔符）天然比根
   长一字符，等值路径永远比不上。后果：`cd repo && nvim` 时 `active()` 解析不到，
   M4 的 `:Vcssign`（不带路径）与 M3 的目录 buffer 全部落空。修法：等值分支返回 `''`。
2. **major（已修）**：世代号只覆盖 `detach` 路径 —— `_remove`（仓库消失）与 `dispose_all`
   （退出）都不推进它，晚到的检测回调会把已释放/已全灭的引用重新建仓（监听 + status 进程）。
   修法：`attach` 进入即递增（**最新者胜**）+ `_remove` 逐 ref 递增 + `dispose_all` 递增
   模块级 epoch（覆盖「从未绑定、无 `_gen` 条目」的在飞引用）。
3. 自己暴露的第三条：`refresh_now` 不取消已武装的防抖 —— 窗口内夹一次手动刷新，
   同一批变更跑两遍 `git status`。`_do_refresh` 起跑前 `_refresh_cancel()` 一行修掉。

其余：重试 timer 取消后不多跑（`armed` 判定）、exec 防御分支 nil 安全、metadata 事件
在更新期间**记为 pending 而非丢弃**（否则完全落在 status 窗口内的 `git add` 会永久丢失）、
waiter 陈旧语义文档化、`!!`/`X`/`I` 前向兼容注释。`get_by_path` 的双 normalize 不修
（仓库数个位数，正确性优先）。

全量 **81/81** 两遍幂等（repo_spec 21 例，含 3 个新回归用例）。

## 附录 F · M3 实测记录（Windows 11 · nvim 0.12.4）

全部结论都由探针直接观测，不是推断：

1. **`nvim_open_win` 支持 `split`**：`nvim_open_win(buf, enter, { split = "right", width = 40 })`
   建出右分屏、直接显示该 buffer、不改变当前窗口的 buffer —— 计划草案里的
   `vim.cmd("vertical resize")` + `win = 9999` 一套可以删掉。
2. **headless nvim 仍然维护屏幕网格**：`vim.fn.screenstring(row, col)` 能读到真实渲染结果，
   连 sign 位字符都在。于是「两个 sign 列顺序对不对」可以写成渲染断言（`sidebar_spec`
   实测 `│ A M` / `│ A  ` / `│ M  ` / `│ U  `）。
3. **sign 列顺序**：同列位里 **priority 高的靠左**；列宽不足时保留 priority 高的那个。
   计划草案给 upstream 位 `+100`，但本地最高优先级是 `conflicted = 100`，
   `+100` 不能保证「有 index 位就一定有 index 位」→ 改 `+1000`（`renderer.upstream_offset`）。
   双列读起来就是 `git status --short` 的 XY。
4. **`sign_text = ' ' .. symbol` 的两字符 sign 占 2 个单元格**：`signcolumn=yes:2` 固定占 4 格，
   **没有 sign 的行也占**（正文始终从第 5 格开始）→ 截断宽度按 `width - 4 - 1` 计算。
5. **`vim.deepcopy` 一个 Repo 会抛**（`Cannot deepcopy object of type userdata`，Repo 持有
   `uv_fs_event_t`）→ `sidebar.forget_all()` 改成浅拷贝值列表再遍历。探针先炸出来的。
6. **`capture_notify` 必须排空 `vim.schedule`**：`log` 全部经 `vim.schedule` → 同步还原
   `vim.notify` 会让这些 warn 绕过桩、污染 stderr 并让断言漏掉它们。
7. **1000 行渲染 7ms**（build 1.7 + draw 5.3，三次采样 6.5/7.5/6.8）→ 远低于 300ms 去抖窗口，
   全量 clear + 重画这个策略站得住，条目级增量更新无需做。
8. **按键可以真实按**：headless 下 `nvim_feedkeys('r', 'x', false)` 会走 buffer-local 映射
   （`q` 关窗、`r` 刷新都实测过）；`<CR>` 要用真实 `` 字节，`'<CR>'` 这种记法不展开。

### 实现期自己踩到并修掉的三个坑

| # | 现象 | 原因 / 修法 |
|---|------|-------------|
| 1 | `forget_all()` 抛 `Cannot deepcopy object of type userdata` | Repo 持 libuv 句柄 → 浅拷贝值列表（见上 #5） |
| 2 | `sidebar_spec` placeholder 用例超时 | `item_at(buf, row)` 是 **0 基**行号，spec 里当 1 基用了 → 断言改成读行模型首行；0 基约定已写进 03 §4/§7.2 |
| 3 | 测试输出里混入 `Already only one window` 与 `vcssign: no handler for action stage` | `:only` 在单窗口时也会发消息（`reset()` 里先判窗口数）；`log.warn` 是 `vim.schedule` 投递的（`capture_notify` 排空后就被捕获，不再漏到 stderr） |

### 测试与工程门

- 全量 **107/107**（M1 53 + exec 7 + repo 21 + renderer 13 + sidebar 13），两遍幂等。
- stderr 只剩 1 行预期 warn（M2 退避重试用例），其余全部被捕获或消除。
- `git diff --check` 干净；`temp/` 只剩共享 fixture（`temp/_spec/` 由 `helpers.cleanup()` 清掉）。

## 附录 G · M3 独立代码审查（code-reviewer）与修复

范围 `cab8f47^..62b8005`，结论 **无 critical，1 major + 11 minor**；逐条核实后全部处置
（定论表在 `03-sidebar-ui.md` §7.4，此处只记最值得记住的）：

1. **major（已修）**：占位横幅沿用了「截头留尾」——那是给路径写的规则（文件名在尾部），
   但错误消息的有效信息在**开头**。默认 40 列下
   `fatal: not a git repository (or any of the parent directories): .git`（66 字符，预算 35）
   会只剩括号里的尾巴。现在路径 `keep_tail` / 消息与标题 `keep_head`，并有用例。
2. **minor（已修）**：`_states` 只按 root 建键、bufname 却带 system → 同 root 双系统会互相顶掉。
   键改成 `system|root` 与 bufname 对齐。
3. **minor（已修）**：`dispatch('close')` 自己 `nvim_win_close`，绕过 owner 留下失效的 `state.win`
   （当前无害，M4 直接读 `state.win` 就会踩）。改调 `sidebar.close`。
4. **minor（已修）**：侧边栏未显示时 `cursor_entry` 回退到「当前窗口光标行」，会静默指到无关文件
   → 未显示就明确提示；顺手删掉 `sidebar.cursor_entry` 那份重复实现。
5. **minor（已修）**：三种 banner 都染红（`no changes` 也是红的）→ 行模型加 `hl`，只有失败是
   `VcssignError`。
6. **minor（已修）**：resize 只挂 `VimResized`，而手动 `:vertical resize` 发的是 `WinResized`
   （0.9+）→ 两个都挂。
7. 保留的取舍：行模型放 `vim.b`（读回整表重建、`entry_at` 返回副本）——1000 行 7ms 在预算内，
   已在 03 §4 写明 M4 按 `path`/`rel_path` 值比较；单 sign 行落在左列（03 §7.3 #6）同理保留。
8. 文档与代码四处不符（严重度顺序把 `added` 写在 `renamed` 前、§3.3 术语与 `+100` 偏移、§6 标准列
   拔高、D6 bufname 少 `<system>`）全部按代码改正；§6 的措辞收敛到用例真正断言的范围。

### 复查新增的用例（+7）

| 用例 | 钉住什么 |
|------|----------|
| renderer: `a failure banner keeps the words that explain the failure` | 消息留头 + 只有失败染红（major 的回归用例） |
| renderer: `the severity order is the one the plan documents` | 13 个状态的顺序字面钉住（文档与代码再也不会各说各话） |
| sidebar: `position = "left" …` | 左分屏：col 0、宽度、被编辑窗口的 buffer 不变 |
| sidebar: `position = "float" …` | 明确 WARN 并回落右边缘（不是静默换行为） |
| sidebar: `resizing the sidebar re-renders the truncated paths` | 两个事件都注册 + 处理器真的按新宽度重画 |
| sidebar: `two systems on one root get one sidebar each` | 状态键与 bufname 一致 |
| sidebar: `a failing or broken action layer is reported honestly` | 动作抛异常→ERROR；模块**加载失败**不再被吞成「未实现」 |

另外：`sidebar_spec` 的 18 个用例统一包 `guarded(fn)`——失败也清场（原来 `reset()` 只在成功路径执行，
一个失败会把残留留给下一个用例，级联失败最难读）；`renderer_spec` 的高亮用例跑完会把自己改过的全局
高亮复原。

## 附录 H · M4 实现顺序与踩坑速记

按「能被验证的最小步」推进，每一步都跑绿再进下一步：

1. **config**（`diff.mode` / `commit.message_input`）→ 2. **actions**（先 stage/unstage：最容易用 VCS 自身核对）→
3. **diff**（缓冲区+窗口，注意复用与只读）→ 4. **commit**（桩 `vim.ui.input`）→ 5. **cli + plugin 薄壳** →
6. **autocmds** → 7. **init 公共 API** → 8. spec 与文档。

踩到并记住的：

- **`vim.system` 的退出回调可能同步发生**：立刻失败的进程（`cwd` 不存在）会在 `vim.system` 返回前回调，
  所以任何「spawn 之后再武装超时定时器」的写法都会漏关（M1 就是这么写的，M4 的句柄断言才把它抓出来）。
- **`until` 是 Lua 关键字**：`local function collect(fn, until)` 直接编译失败。
- **Lua 模式没有多行锚点**：`^…$` 对多行文本等于没断言（写 diff 用例时被骗过一次）。
- **`svn log` 在工作副本上只到 BASE**：刚提交后要查 URL，不是工作副本路径。
- **`vim.fn.fnamemodify(nil, ':p')` 不报错**：它给一个基于 cwd 的怪字符串（`v:/null`），所以入口要 `assert` 参数。
- **跨 spec 的状态会互相影响**：文件/缓冲区/窗口/cwd 都会留到下一个 spec。`reset()` 里加 `enew!` + `cd` 回插件根，
  且断言要针对「本 spec 关心的对象」（例如数 diff 缓冲区时按 `filetype == 'diff'` 过滤，而不是按文件名包含）。
- **破坏性前提的用例要自造环境**：提交需要可写的 svn 服务器 → `helpers.svn_repo` 现造（共享 fixture 只读）。
- **headless 收不到 `FocusGained`**（同 `VimResized`/`WinResized`）：用例用 `nvim_exec_autocmds` 驱动处理器，
  另有用例断言注册本身。

## 附录 I · M4 独立审查（code-reviewer）与修复

范围 `318e1b3..1f3ed6e`，结论 **无 critical，2 major + 约 20 minor**（定论表在 04 §7.4）。两条 major 都值得记住：

1. **动作条目要按「身份」绑定仓库**。`entry.rel_path` 是**渲染它的那个 root** 的相对路径。仓库套仓库时
   （外层把内嵌 checkout 列成一行 `?? inner/`），「包含该路径的最深仓库」是内层——于是外层的相对路径被交给内层
   仓库，stage/diff 作用在错误的树上。修法：`abspath(repo.root, rel_path) == entry.path` 精确匹配。
   这条和 M4 实现时修的 `ensure` 是同一个错的**两个方向**（那次修的是「内层文件被判给外层」）。
2. **侧边栏必须自己持引用**（D18 原文，M4 实现时漏了）。缓冲区比窗口活得久：不然「关掉仓库里最后一个文件」
   会把用户正在看的列表一起拆掉。新增 `repo_manager.hold(ref, repo)`（不探测、不发命令）。

审查还抓到三条我原先没意识到的边界：svn 会把**目录**列成条目而 `svn commit -- <dir>` 递归提交整棵子树
（现在直接拒绝）；`DirChanged` 的细节在 `v:event` 而不是回调参数里（`:lcd`/`:tcd` 也会触发它）；
`VimLeavePre` 清理路径上「侧边栏是唯一窗口」会抛 `E444`，从而跳过句柄释放。

修复后全量 167/167、两遍幂等、stderr 仍只有 1 行预期告警。审查同时确认了 10 条「不是问题」
（exec 四条结束路径都关定时器、D19 在 M4 新代码里成立、钩子隔离、`<f-args>` 无注入面、diff 缓冲复用与
`bufhidden=wipe` 不冲突等），并指出 6 条「已声明的取舍，保留」（最近 marker 解析、每缓冲区一次 attach、
`HEAD` 对比策略、unborn/untracked 的 diff 边界、插件的容量、退出不杀在飞命令）。

## 附录 J · M5 实况与工程门（Windows 11 · nvim 0.12.4）

新增（3 个文件 + 7 个用例）：

| 文件 | 内容 |
|------|------|
| `stylua.toml` | 2 空格 / 单引号 / 100 列 / 行尾保留（gitsigns 同款） |
| `.luacheckrc` | `std='lua51'`、`globals={'vim'}`、spec 的 `ok`/`eq`/`check` 只读全局、排除 `deps/`/`temp/`/`impl/`、`max_line_length=120` |
| `scripts/tools.sh` | 钉版本下载工具到 `deps/`：stylua v2.3.1（4 个平台 asset）、luacheck v1.2.0（Windows exe；其它平台 symlink PATH 上的） |
| `Makefile` | `help`（默认）/ `tools` / `fixtures` / `test [FILTER=]` / `format` / `format-check` / `lint`，依赖只负责凑前置件 |
| `doc/vcssign.txt` | 254 行 8 节；tag `*vcssign.txt*` … `*vcssign-arch*`、`*:Vcssign*`；`doc/tags` 不入库 |
| `test/doc_spec.lua` | 7 用例：文件形状 / tag 唯一且被 `:helptags` 索引 / 配置键与取值 / 子命令 / 键位动作 / 状态与高亮组 / 公共 API |

工程门实测：

```
make format-check   → 零输出（34 个文件：19 lua + 15 test）
make lint           → Total: 0 warnings / 0 errors in 34 files
make test           → 174 tests, 0 failed（两遍一致；stderr 仅 1 行预期重试告警）
```

- 工具版本：stylua 2.3.1、luacheck 1.2.0（PUC-Rio Lua 5.4）。
- 本机原先没有 `make`：`scoop install make` 装了 4.4.1 才验证 Makefile（环境准备，不进仓库）。
- luacheck 抓到的 4 处都不是风格问题，而是「删了也不报错」的未使用变量/函数与两处遮蔽
  （`test/sidebar_spec.lua` 的 `win`、`test/cli_spec.lua` 的局部函数、`test/autocmds_spec.lua` 的 `elsewhere`、
  `lua/vcssign/actions.lua` 里遮蔽 `err` 的变量）；只删/改名，行为不变。
- `git update-index --chmod=+x scripts/*.sh`：本机 `core.filemode=false`，POSIX 克隆要有可执行位只能这么改。
- 遗留 backlog：CI workflow（本机无远端可验证）、`scripts/gen_help.lua`（从 config schema 生成配置段）。
