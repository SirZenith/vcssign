# 05 · 测试仓库（temp/）、测试脚手架、lint / CI / 文档（P4，与 01–03 并行推进）

> 归档自早期计划文档 `05-testing-infra.md`（M0–M6 实施计划，原 `impl/` 目录）。由 2026-10-16 的 `loop/` 迁移整篇移入 `loop/archive/`，状态：**已实现、冻结**。
> 文中 `00`–`07` 的简写指的是本目录下的归档文档，对照表见 `loop/archive/README.md`；
> 被抽取到 `loop/knowledge/` 的小节在正文里只留指针。

> 用户已指定：测试用的 git / svn 仓库放在**当前项目目录下的 `temp/`**。
> **落地状态**：`scripts/make_test_repos.sh` 已实现并实测——从零 `rm -rf temp` 重建、连续跑两次（幂等）、
> 全 44 个 spec 通过。本文件 §2 的代码块是**设计草稿**，以脚本为准；下面用「实测校正」标注与原草稿不一致的地方。

## 0. 前置（已完成）

1. `.gitignore` 追加（**用户已完成并验证生效**）：
   ```
   /temp/
   /deps/
   /.nvimlog
   ```
2. 环境：git 2.55.0.windows.2、svn 1.14.5 + svnadmin、nvim 0.12.4（`vim.system` / `vim.uv` 均可用）。

## 1. 交付物

| 文件 | 职责 | 状态 |
|------|------|------|
| `scripts/make_test_repos.sh` | 幂等生成 `temp/` 下全部测试仓库 | ✅ |
| `scripts/run_tests.sh` | headless nvim 跑 test spec | ✅ |
| `test/run.lua` | 轻量 runner（TAP 输出 + 非 0 退出码 + svn 缺失 SKIP） | ✅（取代原计划的 `test/preload.lua`） |
| `test/helpers.lua` | fixture 路径 / 断言 / 异步阻塞等待 / 通知捕获 / 屏幕单元格读取 | ✅ |
| `test/status_type_spec.lua`、`config_spec.lua` | 枚举与配置不变量 | ✅ |
| `test/vcs_git_spec.lua`、`vcs_svn_spec.lua`、`vcs_registry_spec.lua` | 01 的验收 spec | ✅（42 用例全绿） |
| `test/repo_spec.lua` | 02 的验收 spec（元数据会话：监听/去抖/存活探测/句柄清场） | ✅（20 用例全绿，M6 Step 2 版） |
| `test/exec_spec.lua` | `exec.run` 契约（**回调上下文**/错误结构/超时/spawn 失败/**stdin**） | ✅（13 用例全绿，M6 Step 2 加 4 个 stdin 用例） |
| `test/renderer_spec.lua` | 03 的行模型 spec（纯函数，无仓库/无二进制） | ✅（15 用例全绿） |
| `test/sidebar_spec.lua` | 03 的窗口/按键 spec（真实仓库 + 真实屏幕） | ✅（18 用例全绿） |
| `test/actions_spec.lua` | 04 的动作 spec（真实仓库 + VCS 自身核对 + 桩 `vim.ui.input`） | ✅（24 用例全绿） |
| `test/cli_spec.lua` | 04 的 `:Vcssign` spec（命令分派/补全/目标解析/公共 API/`plugin/` 薄壳） | ✅（17 用例全绿） |
| `test/autocmds_spec.lua` | 04 的生命周期 spec（attach/detach/清理/钩子隔离） | ✅（10 用例全绿） |
| `scripts/tools.sh` | 钉版本把 stylua / luacheck 下到 `deps/`（幂等） | ✅（stylua 2.3.1 / luacheck 1.2.0） |
| `stylua.toml` / `.luacheckrc` / `Makefile` | 工程工具链（gitsigns 同款） | ✅（05 §4，实测 `make 4.4.1`） |
| `doc/vcssign.txt` + `test/doc_spec.lua` | 手写帮助文件 + 「文档与代码不许漂移」的断言 | ✅（7 用例，无外部二进制） |

## 2. temp/ 测试仓库（scripts/make_test_repos.sh）

幂等：每步 `[ -d x ] || ` 判存。git 需设置 `user.email/user.name`（local config，避免依赖全局）。

### 2.1 `temp/git-repo`（主 fixture）

```sh
git init -q temp/git-repo && cd temp/git-repo
git config user.email t@t && git config user.name t
echo base > base.txt
echo old > old.txt
echo 中文内容 > "文件 名.txt"
git add -A && git commit -qm init
# 工作区状态矩阵（全部可重复执行，除 rename 有存在性守卫）:
echo mod > base.txt                     # worktree M
echo new > new.txt                      # ?? (untracked)
echo u > "untracked 名 .txt"            # ?? (空格 + 非 ASCII)
echo staged > staged-add.txt && git add staged-add.txt   # index A
echo sm > staged-mod.txt && git add staged-mod.txt && echo sm2 >> staged-mod.txt  # AM
mkdir -p sub && echo x > sub/x.txt && git add sub/x.txt  # index A（子目录路径）
git mv "文件 名.txt" renamed.txt        # index R + orig_path（需存在性守卫）
rm old.txt                              # worktree D
```

状态矩阵目标（spec 断言的期望集合，与 `test/vcs_git_spec.lua` 一一对应）：

| 状态 | 造法 |
|------|------|
| `worktree M` | 改工作区文件 |
| `worktree D` | 直接 `rm` 已版本化文件 |
| `index A` | `git add` 新文件 |
| `index A + worktree M`（AM） | add 后再改工作区 |
| `index R`（rename + orig_path） | `git mv` |
| `?? untracked`（含空格/中文路径） | 未 add 的新文件 |
| `U conflicted`（UU） | `git merge` 制造冲突（单独一个 `temp/git-repo-conflict`，避免主 fixture 污染） |
| worktree root 检测 | `git worktree add ../git-worktree -b wt`（01 §7 回归点） |

> **实测校正**：
> - 首版计划把「staged modify」用 `git add base.txt` 造，结果它与「worktree M」互相覆盖；
>   已拆成独立文件（`base.txt` 保 M、`staged-mod.txt` 造 AM）。
> - 初始提交的守卫不能只看 `temp/git-repo` 存不存在（重跑时会把脏状态提交进去），必须是 `[ ! -d temp/git-repo/.git ]`。
> - `git init -b main` 要求 git ≥ 2.28（本机 2.55 ✓）。

### 2.2 `temp/svn-repo`

svn 无「本地 init」，需要 `svnadmin`（本机已确认有）。仓库 URL 用 `file:///D:/...`（三斜杠 + 盘符），
由 `pwd -W`（MSYS）或 `pwd`（POSIX）生成：

```sh
svnadmin create temp/svn-server
SVN_URL="$(svn_url temp/svn-server)/trunk"     # file:///D:/.../temp/svn-server/trunk
svn mkdir -q --parents "$SVN_URL" -m init       # 已存在会报错，需先 svn ls 守卫
svn co -q "$SVN_URL" temp/svn-repo
# 初始提交: base.txt / old.txt / missing.txt / repl.txt 四个文件
# 状态矩阵:
printf 'mod\n' > base.txt                       # M
svn propset -q myprop v base.txt                # 第 2 列 M（属性修改）→ MM
printf 'prop\n' > prop.txt && svn add -q --force --parents -- prop.txt   # A
svn rm -q --keep-local old.txt                  # D
rm -f missing.txt                               # !（版本化文件被 rm）
printf 'new\n' > new.txt                        # ?
svn rm -q --keep-local repl.txt && svn add -q --force repl.txt           # R（replaced）
mkdir -p sub2 && printf 'q\n' > sub2/q.txt && svn add -q --force --parents -- sub2/q.txt  # A（目录 + 文件）
```

状态矩阵目标：`M(MM) / A / D / ! / ? / 属性修改 / R(replaced) / 子目录` + `--show-item wc-root` root 断言。

> **实测校正**：
> - `svn add dir/file.txt` 在 `dir` 未版本化时会报 `E200009`，**必须 `--parents`**。
> - `svn add --force` 的语义已实测：已版本化 → 无操作；已调度删除 → 变 `R`；未版本化 → 变 `A`；重复执行幂等。
>   因此**不要**用 `svn info` 做「是否已加入」的守卫（它对已调度删除的路径仍返回信息，会把 R 症状变成 D——本次真实踩到）。
> - `svn rm --keep-local` 重复执行会报错，需先看 `svn status` 首列是不是 `D`/`R` 再决定。

### 2.3 `temp/svn-conflict-a` + `temp/svn-conflict-b`（tree conflict 用例）

wc A 本地编辑 f.txt，wc B 删除 f.txt 并提交，A 再 `svn update` → **真实 tree conflict**。
真实输出（svn 1.14.5 实测）：

```
A  +  C f.txt
      >   local file edit, incoming file delete or move upon update
Summary of conflicts:
  Tree conflicts: 1
```

价值：列 7 的 `C`、`^%s*>` 续行、`Summary of conflicts:` 尾行全部用**真实输出**钉住（
之前的单元用例是自己构造列宽，若列号写错也会全绿）。

### 2.4 `temp/svn-switch`（switched 用例）

服务端 `svn copy` 出一个 branch，再把 wc 的 `sub/` `svn switch` 过去 → 列 5 出现 `S`：

```
    S   sub
```

### 2.5 `temp/nested`（嵌套用例）

`temp/nested` 为 git 仓库，其中 `inner/` checkout 了上面的 svn server（git 里 ignore 掉 `inner`）→ 01 §7.4 的系统切换用例。

### 2.6 退出码矩阵

`temp/` 各仓库全部是「已知状态」的——spec 断言状态**集合与每条 path 域值**，而不是数量（增删 fixture 不破坏断言用「expected ⊆ actual」集合断言）。

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/testing/headless-nvim.md`

---

## 6. 验收标准

1. 全新克隆后：`scripts/make_test_repos.sh` 幂等跑两次，第二次全 skip；`temp/` 结构与 §2 矩阵一致。
2. `scripts/run_tests.sh` 全绿（svn 缺失环境打印 `SKIP svn` 并不失败）。
3. `stylua --check` / `luacheck` 零输出。
4. spec 失败注入（改坏一个断言）→ TAP 输出定位到用例名，exit code 1（CI 可用性验证）。

### M4 之后的实况（167 用例，含审查修复）

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| status_type / config / renderer | 4 + 7 + 15 | 无 |
| exec / repo | 9 + 21 | git（svn 部分用 svn） |
| vcs_git / vcs_svn / vcs_registry | 16 + 18 + 8 | git / svn / 两者 |
| sidebar | 18 | git, svn |
| actions / cli | 24 + 17 | git, svn, **svnadmin** |
| autocmds | 10 | git |

- `svnadmin` 是 M4 新增依赖（`helpers.svn_repo` 现造服务器，见 04 §7.2）；缺它时这两个 spec 会 SKIP 而不是失败。
- 全量跑两遍结果一致（幂等）；**stderr 只应有 1 行**（`runtime-retry` 用例那条预期超时告警）。
  用例若制造了额外噪音要主动消掉：用内部消息的动作结果（stage/commit）在用例里用
  「吞掉通知的包装」跑，`vim.ui.input` 一律打桩。
- 断言 `uv` 句柄数时记住三件事：`exec` 的超时定时器要等命令回答才关（所以先等 status 落地再断言）；
  `helpers.uv_count` 只数「未在关闭中」的句柄；**同步回调**这种形状要用桩复现（`vim.system` 的退出回调可以在
  `exec.run` 返回前就跑，`exec_spec` 用它钉住「定时器先建后 spawn」这条不变量——旧实现下这个用例会红）。
- 通知类断言统一用 `helpers.capture_notify(fn, is_done?)`：不给谓词时只排空 50ms（同步回答够用），
  给谓词时等到达（VCS 命令的回答都是异步的）。三份 spec 早先各抄了一份，M4 审查后收敛到 helpers。

### M5 之后的实况（174 用例）

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| status_type / config / renderer / **doc** | 4 + 7 + 15 + **7** | 无 |
| exec / repo | 9 + 21 | git（svn 部分用 svn） |
| vcs_git / vcs_svn / vcs_registry | 16 + 18 + 8 | git / svn / 两者 |
| sidebar | 18 | git, svn |
| actions / cli | 24 + 17 | git, svn, svnadmin |
| autocmds | 10 | git |

- 工程门（全部实测）：`make format-check` 零输出（34 个文件）；`make lint` = `Total: 0 warnings / 0 errors in 34 files`；
  `make test` = `174 tests, 0 failed`，两遍结果一致，**stderr 仍只有 1 行**预期重试告警。
- 工具版本：stylua 2.3.1、luacheck 1.2.0（PUC-Rio Lua 5.4 / LuaFileSystem 1.8.0）。
- 本机原先没有 `make`，用 `scoop install make` 装了 4.4.1 才验证到 Makefile 真能跑（属环境准备，不进仓库）。
- `make test` 与 `sh scripts/run_tests.sh` 是同一件事：前者多跑 `fixtures`（幂等）与 `tools`（幂等）。

### M6 Step 2 之后的实况（128 用例）

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| config / doc | 7 + 6 | 无 |
| exec / repo | **13 + 20** | git（svn 部分用 svn） |
| vcs_git / vcs_svn / vcs_registry | 16 + 18 + 8 | git / svn / 两者 |
| autocmds | 10 | git |
| actions / cli | 19 + 11 | git, svn, svnadmin |

- 本步后的 spec 清单以**本表**为准（Step 1 删掉侧边栏后，上面 M3/M4/M5 各表里的
  `status_type` / `renderer` / `sidebar` / `actions` / `cli` 计数已过时——统一回写留给 Step 12）。
- 工程门：`make test` = `128 tests, 0 failed`；`make format-check` / `make lint` 干净。
- **stderr 合同（已重测）**：仍然**恰好 1 行**，由 `repo_spec` 用例
  「the backoff retry recovers without any user input」（临时仓库 `temp/_spec/runtime-retry-real`）产生。
  存活探测不再跑 `git status`，所以命令串变了。**逐字原文**（nvim 0.12.4 / git 2.55.0.windows.2）：

  ```
  vcssign: D:/Developer/nvim-plugins/vcssign/temp/_spec/runtime-retry-real: timeout after 1ms: git --no-pager --no-optional-locks --literal-pathspecs -c core.quotepath=off -c gc.auto=0 rev-parse --show-toplevel
  ```

  （旧值是以 `status --porcelain=v1 -z --untracked-files=all` 结尾、路径为 `runtime-retry` 的那条；
  断言时不要硬编码旧串。）（其余用例的告警都被主动吞掉：`repo_spec` 的失败用例把 `vim.notify` 打桩、
  `actions`/`cli` 的通知类断言走 `helpers.capture_notify`。）

### M6 Step 3 之后的实况（158 用例）

在 Step 2 表上再加两张纯函数 spec：

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| `hunk_spec` | 20 | git（真跑 `git apply` 的三个用例） |
| `diff_spec` | 10 | git（`REQUIRES` 门槛，运行时其实只用 nvim 内置引擎） |

- 工程门：`make test` = **`158 tests, 0 failed`**（= 128 + 30）；`make format-check` / `make lint` 干净。
- stderr 合同不变：仍是**恰好 1 行**（同 Step 2 那条 `rev-parse --show-toplevel`），Step 3 没有新增告警。
- `diff.lua` / `hunk.lua` 是**纯函数**（D39：不起外部 `git diff`），`hunk_spec` / `diff_spec` 只依赖 `vim.text.diff`。

### M6 Step 4 之后的实况（150 用例）

适配器换成交互原语后，`status` 解析链的用例整批退役，新接口的用例补上：

| spec | 用例数 | 变化 |
|------|--------|------|
| config / doc | 7 + 6 | 不变（`linematch` 只改取值，`doc_spec` 不查取值） |
| exec / repo | 13 + 20 | 不变 |
| `vcs_git_spec` | **16 → 14** | 删 9 条 status/`parse_status`（矩阵、绝对路径、rename `orig_path`、冲突、linked worktree 干净、四条列映射、子目录不重复根）；加 7 条：show 读 index 基线而非工作区、`is_tracked` 对未跟踪返回 false、`blame` 逐行归属 + `-L` 窗口、`apply_patch --cached` 正/反、`apply_patch` 工作区正/反、补丁缺尾 `\n` → `corrupt patch`、`revert` 回到 index |
| `vcs_svn_spec` | **18 → 12** | 删 13 条 status/`parse_line`/`parse_status`（固定列映射、真实 tree conflict、switched 列 5、CRLF/孤立 CR、状态矩阵…）；加 7 条：caps 新键、show 的 `BASE`/显式 rev/未纳管报错、`is_tracked`、`blame --xml` 解析（本地已改行 rev=`-`）、`apply_patch` 正向/反向/**只认 strip 0 方言**、拒绝 hunk 报错且删临时补丁文件、`revert` 回 BASE |
| `vcs_registry_spec` | 8 | 不变（stub 用空 caps，不碰键名） |
| `autocmds_spec` | 10 | 不变（`FocusGained` 用例改数 refresh pass） |
| `actions_spec` | 19 | 用例数不变；删掉 `entry_of`/`entry`/`wait_for_domain`，改用真实 VCS 查询 + `helpers.count_refreshes`；两条改名为「diff shows a unified diff of the worktree change」「diff uses the configured baseline: the index by default」，一条改为「a path is acted on in the deepest repository containing it」 |
| `cli_spec` | 11 | 不变（只有「the public API refreshes without a prior attach」换观测点） |

- `test/helpers.lua`：删掉 `status_set` / `entry` / `status_entries`（唯一消费者是上表里改掉的那些用例），
  新增 `count_refreshes(repo)`——把实例的 `_do_refresh` 换成一个计数器，因为 D38 之后「刷新落地了」
  只剩机制可观测（`refresh_now` 是 `self:_do_refresh()` 动态查找，实例字段能遮蔽方法）。
- 工程门：`make test` = **`150 tests, 0 failed`**（158 − 8）；`make format-check` 干净；`make lint` = `Total: 0 warnings / 0 errors in 31 files`。
- stderr 合同不变：仍是**恰好 1 行**（同 Step 2/3 那条 `rev-parse --show-toplevel`），本步没有新增告警。

### M6 Step 5 之后的实况（178 用例）

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| config / doc | 7 + 6 | 无 |
| exec / repo | 13 + 20 | git（svn 部分用 svn） |
| vcs_git / vcs_svn / vcs_registry | **14** + **13** + 8 | git / svn / 两者 |
| hunk / diff | **20 + 10** | git |
| signs / attach | **13 + 14** | git |
| autocmds | 10 | git |
| actions / cli | 19 + 11 | git, svn, svnadmin |

- 工程门：`make test` = `178 tests, 0 failed`；`make format-check` 零输出；
  `make lint` = `Total: 0 warnings / 0 errors in 35 files`。
- **stderr 合同要改写**：行数现在在 **0/1 之间浮动**。那一行仍来自 retry 用例
  （`exec_timeout_ms = 1`）的 `log.warn`，是否出现取决于命令有没有在 1ms 内跑完，用例本身不断言它。
  **别再按「恰好 1 行」写验收** —— Step 14 要么断言 0–1 行，要么把该用例的告警主动捕获掉。
- **`FILTER=<spec> make test` 也必须绿**（这是本节新增的判据）。Step 2 引入的回归
  （工作副本被删后 `Repo` 不自杀，见 07 §6.1）在 `3ecbdd7` / `5e8e485` / `7acc713` 上让
  `FILTER=repo_spec` **稳定 2/20 红**、全量运行**间歇红**；`f1d1735`（root 上的非递归存活 watch）
  修好后连跑两次 20/20 绿。**全量绿 ≠ 该 spec 单独跑绿**，两者都要测。
- `hunk_spec` / `signs_spec` 是纯函数与放置规则 spec（读 extmark details，不依赖屏幕渲染）；
  `attach_spec` 才用真仓库 + `helpers.screen_line` 断言 `signcolumn` 单元格。
- 高亮断言后要复原（先 `highlight clear <组>` 再 `define_highlights()`），
  `renderer_spec` 与 `signs_spec` 同法。

### M6 Step 6–11 之后的实况（244 用例）

| spec | 用例数 | 需要的外部命令 |
|------|--------|----------------|
| config / doc | 7 + 6 | 无 |
| exec / repo | 13 + 20 | git / git + svn |
| vcs_git / vcs_svn / vcs_registry | 14 + 13 + 8 | git / svn / 两者 |
| hunk / diff | 20 + 10 | git |
| signs / attach | 14 + 20 | git / git（attach 另有 svn 用例） |
| nav / worddiff / preview | 13 + 9 + 7 | git（`nav_spec` 只喂手工 hunk 表） |
| blame / revdiff | 8 + 7 | git + svn |
| autocmds / actions / cli | 12 + 30 + 13 | git（actions / cli 还要 svn + svnadmin） |

- 工程门（`22ad24a`）：`make test` = **`244 tests, 0 failed`**；`make format-check` 零输出；
  `make lint` = `Total: 0 warnings / 0 errors in 46 files`。
- **子集单跑**：`sh scripts/run_tests.sh <spec…>`；`Makefile` 的 `FILTER` 只是把它透传过去
  （`FILTER=nav_spec make test` = 13/13，实测有效）。**「全量绿」与「本步动到的 spec 单跑绿」是两条
  独立判据** —— 跨 spec 的顺序依赖是已知的 flake 源（上一条用例的在制品异步命令会落进下一条的
  观察窗口）。
- **两个要会解读的现象**：① `repo_spec` 对负载敏感 —— 侧边同时跑 `svnadmin` / `svn patch` 这类重命令时，
  `a metadata change is announced exactly once` 会等不到 fs 事件而红（空闲连跑 3 次 20/20 绿）；
  ② `log.warn` 直接写 stderr，会**插进 TAP 行中间**（实测丢了第 62、209 行，但 `244` 的计数对得上）
  —— 看结果用 `grep "not ok"`，别按行号定位。
- 每个用例都包 `guarded(fn)`：失败也清 `touched` 缓冲区 / `attach.forget_all()` / `manager.dispose_all()` /
  `config.setup({})`，否则下一条用例会继承上一条的去抖定时器。
- 新 spec 的分工：`nav_spec` / `worddiff_spec` / `preview_spec` / `blame_spec` 的纯函数部分不碰仓库；
  `attach_spec` / `actions_spec` / `revdiff_spec` / `repo_spec` 用真仓库，`blame_spec` / `actions_spec`
  还有 svn 用例（`helpers.svn_checkout` 共享 `temp/svn-server`）。

> 本节已抽取到（归档后不再维护）：
> - `loop/knowledge/testing/headless-nvim.md`
