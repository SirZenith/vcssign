# 08 · 性能与架构审查（M6 后全量）：实测数据与优化路线（M7 候选）

> **为什么写这份文档**：用户要求审查当前代码「性能、架构上可优化的部分」（m00001）。方法不是静态猜测，
> 而是先通读全部 `lua/vcssign/`（24 个模块，约 7000 行），再用 headless 探针实测：给 `exec.run` 打桩数
> 进程、给 `attach._render` 打桩数渲染、对 `diff.run` / `signs.place` 等做微基准。结论一句话：
> **算法层（diff / hunk / extmark）几乎都不是瓶颈，瓶颈在「每次渲染固定的进程数」与「无差别重复的
> 整文件管线」**——这两件事都在架构层（`VcsSystem` 接口缺批量原语、`Repo→attach` 缺「哪个文件变了」的
> 通道），上层单独修补修不掉。
>
> **状态：审查记录，未实施。** 可勾选的实施清单见 §6（M7 候选）；D46 的三约束（不引入 async 框架 /
> 不新增依赖 / 不动 D19）在本文所有建议里**继续有效**（见 §8）。
>
> **两个 VCS 都在范围内（m00225 追问后补齐）**：插件默认同时支持 git 与 svn（`config.systems`），
> 而两者的能力面不同（svn 无 index、无 `-L` blame、无 blob 批协议）。本文第一版只在 fallback
> 处提到 svn，数字全来自 git——那是不够的。**§2.1 / §2.2 已补 svn 实测数据**（svn 每次渲染
> 是 2 个进程但单价更高，**≈144 ms 反而比 git 的 ≈129 ms 更贵**），**§3.5 给出逐条发现的
git/svn 适用矩阵**，并把三条 git-only 的结论（P0-2 / P1-2 / P1-3 的 `-L` 部分）明确标记出来。
> 未因 svn 而改变的结论：**P0-1 / P0-3 / P0-4 / P0-5 对两类 VCS 都成立**，架构缺口（A1/A3）同样。

## §0 编号说明

本文的发现编号 `P0-x` / `P1-x` / `P2-x`（P = perf finding，按影响降序）、**svn 专属的 `S1–S3`**
（S = svn finding）与架构结论 `A1–A5` 是**本文私有**编号，与 `07` §10 backlog 里引用的旧审查编号
（「审查 F5 / F9」）无关。逐条发现的 git/svn 适用性集中看 **§3.5 的矩阵表**。

## §1 审查方法与环境

| 项 | 值 |
|----|----|
| 环境 | Windows 11 · NVIM v0.12.4（Release，LuaJIT 2.1.1774638290）· git 2.55.0.windows.2 · svn 1.14.5 |
| 范围 | `lua/vcssign/` 全量（含 `vcs/` 子层）+ 生命周期（attach / autocmd / actions / repo / manager） |
| 探针 fixture | git：`temp/bench-repo`（新建，20 个已跟踪文件、每个都有改动；用后已删）。svn：`temp/svn-repo`（`scripts/make_test_repos.sh` 生成的共享 fixture，6 个可读文件、1 个已修改） |
| 探针形态 | 见下；探针是一次性脚本，用完删除，**复现方法以此文为准**。git 侧：`temp/bench.lua` / `bench2.lua` / `e2e.lua` / `e2e2.lua` / `e2e3.lua` / `proc.lua`；svn 侧：`temp/svnbench.lua`（单价）/ `temp/svne2e.lua`（计数）。**例外：`temp/probe_p04.lua` 保留**——它服务 §2.4 的前后对比，M7 步骤 2–6 还要接着用（`nvim --headless -u NONE -l temp/probe_p04.lua git|svn`，一次只跑一类 VCS） |

进程/渲染计数探针的核心形态（M7 落地时应固化为回归测试，见 A4）：

```lua
local exec = require('vcssign.exec')
local orig = exec.run
exec.run = function(cmd, opts, cb)  -- 计进程 + 按子命令归类
  -- git: cmd[1] 固定为 'git'，子命令在 argv 里的固定偏移；svn 同理但要以 `--non-interactive` 后的项为键
  count[key(cmd)] = (count[key(cmd)] or 0) + 1
  return orig(cmd, opts, cb)
end
local attach = require('vcssign.attach')
local orend = attach._render
attach._render = function(st) renders = renders + 1; return orend(st) end
require('vcssign').setup()  -- 之后 :edit 若干文件、vim.wait 到计数稳定（连续 4×50ms 不变）
```

**读数注意**：本机 Windows 的 spawn 单价偏高（§2.1）；Linux 上单次 `git` spawn 只要几毫秒，
**毫秒数会整体缩小一个量级，但「每次渲染调几次进程」的计数是平台无关的**——本文的 P0 结论
以计数为准，不依赖绝对时间。**两类 VCS 都要单跑一遍**：svn 的进程数天然比 git 少一个
（无 staged 层），但单价高（§2.1），两者不能互相推算。

## §2 实测数据

### §2.1 子进程单价（`temp/proc.lua`，`vim.system():wait()` 各 20 次均值）

| 命令 | 单价 |
|------|------|
| `git rev-parse --show-toplevel` | 42.8 ms |
| `git ls-files --error-unmatch -- f1.lua`（**单文件**） | 43.4 ms |
| `git show :f1.lua` / `git show HEAD:f1.lua` | 42.6 / 43.6 ms |
| `git diff -U0 -- f1.lua` | 42.5 ms |
| **`git status --porcelain -z`（整个仓库）** | **44.4 ms** |
| `git cat-file --batch`（常驻进程，首请求） | 47.1 ms |

svn 侧同法实测（`temp/svnbench.lua`，同一台机器、同一个 `vim.system():wait()` 形态、各 10 次均值）：

| 命令 | 单价 |
|------|------|
| `svn info --show-item wc-root` | 52.6 ms |
| `svn info -- <file>`（`is_tracked`） | **82.5 ms** |
| `svn cat -r BASE <file>`（`show`） | **62.0 ms** |
| **`svn status --xml`（整个 wc）** | **63.9 ms** |
| `svn status`（纯文本，整个 wc） | 62.8 ms |
| `svn blame --xml <file>` | 74.7 ms |
| `svn info` **一次带 6 个目标** | **54.2 ms**（见 S2） |

**关键事实一：一次「整个仓库」的批量查询与一次「单文件」查询几乎同价**（git 44 vs 43 ms；
svn 63.9 vs 82.5 ms）。现在的实现为每个 buffer 每次渲染问几个**单文件**问题，而这些问题一次
批量查询就能全部回答——这是 P0-1 / P0-2 的全部依据。

**关键事实二：svn 的每个进程都比 git 贵**（`info` 82.5 / `cat` 62.0 vs git 全线 ≈43 ms）。
svn 没有 staged 层（`capabilities.staged_signs = false`，`lua/vcssign/attach.lua:145` 的
`wants_staged` 因此为假、`load_head` 整个跳过），所以它每次渲染只有 **2** 个进程
（`svn info` + `svn cat`），但 **2 × 72 ms ≈ 144 ms 反而比 git 的 3 × 43 ≈ 129 ms 更贵**。
换言之：**进程数的最优解在两类 VCS 上不同，但「按仓库批量问一次」对两边都是同一个答案。**

### §2.2 端到端计数（`e2e.lua` / `e2e2.lua` / `e2e3.lua`）

| 场景 | 实测 |
|------|------|
| 打开 1 个已修改文件 | **5 个进程**：`rev-parse`×2、`ls-files`×1、`show`×2（次序见 §3 P0-5） |
| 打开同仓库 20 个文件 | **141 个进程 / 2155 ms / 54 次渲染**（`rev-parse`=24、`ls-files`=39、`show`=78）；1 个 Repo |
| `FocusGained`（磁盘**无任何变化**） | **+40 渲染 / +120 进程**（`show`=80、`ls-files`=40）= 每 buffer 恰好 2 次渲染、6 个进程，产出零差异 |
| 一次普通编辑（200ms debounce 静默后） | **3 个进程**（`ls-files`+`show`×2）、809 ms 才静默——基线没变也要整趟重拉 |

svn 侧同形探针（`temp/svne2e.lua`，`temp/svn-repo`，6 个可读文件、其中 1 个已修改）：

| 场景 | 实测 |
|------|------|
| 打开 1 个已修改文件（svn） | **4 个进程 / 1 次渲染**：`svn info`×3（wc-root ×2 + `is_tracked`）、`svn cat`×1 |
| 再打开 5 个文件（共 6 buffer） | **23 个进程 / 11 次渲染**（`info`=12、`cat`=11）≈ **每 buffer 4.6 进程 / 1.8 渲染** |
| 全部 buffer `mark_dirty`（模拟编辑） | **12 个进程 / 6 次渲染** = 每 buffer **2 进程 1 渲染** |
| `FocusGained`（磁盘**无任何变化**） | **13 个进程 / 6 次渲染** = 每 buffer 2 进程，产出零差异 |

与 git 的差别只有两点，且都在预期内：svn **少一个进程**（无 staged 层），但**每次渲染只跑
1 趟**（git 是 2 趟——正是 P1-1 的「双路径」在 git 上的痕迹）。P0-4 的浪费在 svn 上同样成立
（`FocusGained` 13 个进程零产出）；换算成墙钟：svn 每 buffer 每次刷新约 144 ms，git 约 129 ms。

单文件 attach 的完整进程序列（`e2e3.lua`，最干净的证据）：

```
1 rev-parse --show-toplevel     ← registry.detect_async（vcs/init.lua）
2 rev-parse --show-toplevel     ← Repo:_do_refresh 的存活探测（重复，见 P0-5）
3 ls-files --error-unmatch -- f1.lua   ← load_base：is_tracked
4 show :f1.lua                  ← load_base：基线（index）
5 show HEAD:f1.lua               ← load_head：staged 层基线
```

### §2.3 CPU 侧微基准（`bench.lua` / `bench2.lua`，纯内存、零进程）

| 项 | 实测 |
|----|------|
| `diff.run` 2000 行、2% / 25% / 100% 改动 | 0.6 / 0.9 / 0.4 ms |
| `diff.run` 5000 行、2% / 25% 改动 | 1.3 / 2.3 ms |
| `diff.run` **40000 行全改写**（`max_file_length` 上限最坏情况） | 8.1 ms |
| staged 层第二次 `diff.run`（2000 行、2%） | +0.4 ms |
| `signs.place` 未跟踪文件 500 / 2000 / 5000 行（= 同数 extmark） | 0.4 / 1.5 / 3.8 ms |
| `signs.define_highlights()`（每次 attach 都跑） | 0.17 ms |
| `signs.place` 内 `config.get()` ×8 | 未单独计时（P2-2 顺手改） |
| `worddiff.render` / `preview.render_deleted` **已禁用时**仍被调用 | 0.002 / 0.001 ms（纯清空） |
| `worddiff.ranges` 200 对改动行（opt-in 开启后） | 2.2 ms |
| `base.relpath` 单次 / 10 个 root（`get_by_path`） | 0.032 / 0.25 ms |
| `util.emit` 8 个订阅者（含 `vim.deepcopy`） | 0.0009 ms |
| `nvim_buf_get_lines(0,-1)` + `diff.join`，5000 行 | （P0-4 短路后这才是渲染主体） |

**读法**：CPU 侧全部在个位毫秒级，即使 40000 行的最坏情况也才 8.1 ms——「diff 慢 / extmark 多」
都不是真问题；对照 §2.2，每次渲染 **129 ms 量级的进程开销**才是主体。P0 全部指向进程数与重复管线。

### §2.4 P0-4 修复后复测（`temp/probe_p04.lua`，前后同一探针、同一 fixture）

M7 步骤 1 落地后重跑 §2.2 的两个场景。探针按 VCS 分进程跑（同一进程里挂两个仓库会让存活探测
串味），计数口径不变：`exec.run` 每被调用一次 = 1 个进程；渲染数 = 进入 `attach._render` 的次数
（短路返回也算一次进入），所以「渲染次数不变、进程归零」正是短路生效的证据。

| 指标 | git 前 | git 后 | svn 前 | svn 后 |
|------|--------|--------|--------|--------|
| `FocusGained` 进程数（git 20 buffer / svn 6 buffer） | **121** | **1** | **25** | **1** |
| `FocusGained` 同步耗时（`refresh_all` 返回前） | 80.1 ms | **3–5 ms** | 72.2 ms | **0.6 ms** |
| `FocusGained` 渲染进入次数 | 40 | 40 | 12 | 12 |
| 一次编辑（编辑+撤销两趟）的进程数 | 6 | **0** | 2 | **0** |
| 一次编辑墙钟（到静默） | 1225 ms | 965 ms | 1106 ms | 961 ms |
| 首次 attach 20 文件（未动，留作对照） | 62 | 62 | 14 | 14 |

读法与三条结论：

- **进程 121 → 1**：只剩 `Repo:_do_refresh` 的存活探测（`rev-parse` / `svn info --show-item
  wc-root`）。它不能省——仓库被 `rm -rf .git` 之后只有它能发现（`repo.lua` 的 `_on_alive`）。
  所以 P0-4 的验收口径是「每仓库 1 个」，不是绝对 0；要再往下压属于 P0-3（事件替代轮询）。
- **渲染进入次数不变（40 / 12）**：短路是「进去了才判断」，不是「不进入」。省掉的是
  `nvim_buf_get_lines(0,-1)` + 两次 `vim.text.diff` + 两轮 `signs.place`——同步耗时
  80.1 → 3–5 ms 就是这笔钱。40 次进入里一半来自 `refresh_all`、另一半来自 `repo` 的
  `on_update` → `mark_dirty` 触发的第二轮：**这第二轮就是 P0-3 要消掉的重复路径**，现在它
  便宜（短路）但本不该存在。
- **编辑 6 → 0 进程**：纯 buffer 编辑不碰 VCS，基线由元数据 stat 回答。剩下的 965 ms 墙钟是
  两次编辑各自的 200 ms debounce 加探针的 400 ms 静默窗，不是 VCS 的账。

回归口径：`test/attach_spec.lua` 新增 4 例（纯编辑 0 进程、未移动的基线不重读、外部 `git add`
后仍然重读、`config.setup` 之后仍然重画），`test/vcs_git_spec.lua` / `test/vcs_svn_spec.lua` 各新增
2 例（`baseline_stamp` 跟随 index+分支 / 跟随 `wc.db`，以及仓库外返回 `nil`）。全文 268 例通过。

### §2.5 P0-3 修复后复测（同一探针，新增「外部改写一个文件」场景）

「前」列用 `git stash push -- lua/` 在同一个探针上量的 HEAD 树（即 M7 步骤 1 之前的状态，
两者都未提交），所以这张表包含步骤 1 + 步骤 2 的合计收益；**P0-3 单独的增量**看 §2.4 的
「后」列对比本表：`FocusGained` 渲染进入次数 40 → 20（git）/ 12 → 6（svn），进程数不变。

| 指标 | git 前 | git 后 | svn 前 | svn 后 |
|------|--------|--------|--------|--------|
| 外部改写 1 个文件 → 被**进入**渲染的 buffer 数 | **20** | **1** | **6** | **1** |
| 同场景进程数 | 61 | **1** | 13 | **1** |
| 同场景墙钟（到静默） | 2017 ms | 996 ms | 1466 ms | 1061 ms |
| `FocusGained` 渲染进入次数 | 40 | **20** | 12 | **6** |
| `FocusGained` 进程数 / 同步耗时 | 121 / 66.1 ms | 1 / 2.6 ms | 25 / 65.3 ms | 1 / 0.3 ms |
| 首次 attach（对照，本条未触及） | 62 | 62 | 14 | 14 |

读法与四条结论：

- **通道的语义是「证据」，不是「请求」**：`mark_dirty` / `refresh` / `refresh_now` 都不入账
  （它们只说「再看一眼」，不是「什么变了」），只有 fs 事件入账。§2.4 里 40 次进入的另一半
  ——`on_update` → `mark_dirty` 的重复路径——就是这么消掉的（40 → 20）。
- **工作区事件能指认文件**：根 watch 是非递归的，libuv 会给出 `filename`，于是外部改写一个文件
  只进入那一个 buffer（git 20 → 1、svn 6 → 1），省下的是每个 buffer 的 3 个 `show`/`cat` 与
  两次 diff。**元数据事件不指认**（`.git/index` / `.svn/wc.db` 是整仓共享的一份），走全员失效。
- **只对「存在的普通文件」收窄，这是本条的正确性关键**。目录汇总事件（实测 Windows 上一次
  `git add` 会在根 watch 上以 `filename = '.git'` 触发）、已消失的路径、marker 本身，一律回落
  到「全员」。若把目录事件当成某个文件的路径，它下面的 buffer 就会被跳过——静默漏刷新。
  实现用 `uv.fs_stat(path)` 的 `type == 'file'` 判，一次 syscall，不 spawn。
- **一个 Lua 坑记一笔**：`x and nil or y` 永远得不到 `nil`（`and nil` 是假值）。本条第一版
  在 `_take_changes` 与 marker 特判两处都写了这个惯用法，结果是「全员失效」被悄悄降级成
  「只有一个文件」，四个新断言里两个当场超时。现在两处都是显式 `if`。

回归口径：`test/attach_spec.lua` 新增 3 例（事件只进入它指认的 buffer、无事件背后的探测不进入
任何 buffer、元数据变化全员进入）+ `watch_renders()` 计数器；`test/repo_spec.lua` 新增 4 例
（工作区事件指认文件、元数据事件不指认、无事件背后的探测给空集、svn 的 `wc.db` 同样不指认）。
全文 275 例通过。

**为什么不需要给路径折大小写**：`st.path` 与记账键都经同一个 root 的 `base.normalize`
（`vim.fn.fnamemodify(':p')` 会解出磁盘上的真实大小写——实测用 `d:/…` 打开 buffer，`st.path`
仍是 `D:/…`），所以可以直接字符串比较。symlink/junction 指进仓库这类情形本来就在
`repo_manager.relpath` 那一层不成立，不是本步引入的风险。

## §3 发现清单（按影响降序）

### P0 · 进程数量（性能的主要来源）

**P0-1 每次渲染固定问 2–3 个单文件问题**（git：`ls-files` + `show :rel` + `show HEAD:rel`；
svn：`info` + `cat -r BASE`——无 staged 层，见 §3.5）。
`lua/vcssign/attach.lua:183`（`load_base`：`is_tracked` 后 `show(rev)`）与
`lua/vcssign/attach.lua:157`（`load_head`：`show HEAD`）。§2.2 的 20 文件场景里 141 个进程
几乎全部由此而来（≈129 ms 纯开销/渲染窗口）。§2.1 表明一次 `git status --porcelain=v2 -z`
（44 ms，全仓库）/ `svn status --xml`（64 ms，整个 wc）就能回答「谁被跟踪 / 谁有 staged 变更 /
谁干净」——**无 staged 变更时（绝大多数时间）`show HEAD` 可以整个省掉**；svn 上更彻底：
**干净文件（status 里根本不出现）连 `cat` 都不用发**，hunks 必然为空。
→ 建议：`Repo` 上恢复一份**批量状态缓存**（A1/A2），`is_tracked`、`show HEAD` 的取舍、
以及「要不要 `show`」都由缓存回答；缓存失效锚定 fs_event（A3），不靠 TTL。

**P0-2 `show` 没有常驻进程（仅 git；svn 无等价协议）**。
`lua/vcssign/vcs/git.lua:164`（`git show <rev>:<rel>`）是每次渲染最贵的一类调用，且天然可合并：
`git cat-file --batch` 一个进程服务全会话的全部取 blob 请求（§2.1 实测启动 47 ms，此后每请求
0 spawn）。接口只需加一个可选的 `read_blobs(root, specs, cb)`：git 用常驻进程 + 排队。
**svn 这一条不适用**——svn 没有 blob 批协议，`svn cat` 多目标是把内容**直接拼接**、无分隔符，
不可用作 blob 读取；`lua/vcssign/vcs/svn.lua:122` 的 `M.show` 只能逐文件（进程单价 62 ms）。
svn 侧的对应收益全部来自 P0-1 的 status 缓存：**干净文件不取基线**，比省一个进程更彻底。
注意这是**长驻 `vim.system` 进程**，不违反「不新增依赖」（§8），但 git 侧才需要它。

**P0-3 fs_event 收下了 `filename` 却丢掉了它 → 任何变化全员刷新**。
`lua/vcssign/repo.lua:454` 的 `_on_fs_event(watch_path, err, filename, events)` 拿到 `filename`，
但除 `.git/index` 特判（`:483` 附近）外最终只 `self:mark_dirty()`（`lua/vcssign/repo.lua:487`）。
于是**一个文件的变化 → 仓库内所有 buffer 整趟重跑**（load_base + load_head + 2×diff + extmark）。
→ 建议：`repo:on_update(fn)` 加 `changed_paths` 参数（非元数据事件 → 相对路径集合），
`attach` 只刷新受影响的 buffer；索引/HEAD 变化才做仓库级失效（交给 P0-1 的状态缓存）。
**两类 VCS 都吃这条**，但失效锚点不同：git 是 `.git/index` + `HEAD`，svn 是 `.svn/wc.db`
（`svn add` / `revert` / `patch` 都会写它）；svn 侧另见 S1（watch 落点）。

> **状态：已修（M7 步骤 2），前/后实测见 §2.5。** 落地的形状：`Repo` 记「这一轮 fs 事件指的是
> 哪些文件」（`_record_change` / `_take_changes`），`on_update(fn)` 的第二个参数三态——
> 集合 = 这些文件、`nil` = 有事但指认不了（元数据 / 目录 / 已消失）、空集 = 什么也没动
> （探测类请求）；`attach` 只在 `not changed or changed[st.path]` 时 `mark_dirty`。工作区事件
> 靠 `filename` 收窄，元数据事件（以及 `uv.fs_stat` 说明它不是普通文件的一切情况）走全员。

**P0-4 渲染没有短路：`_render` 无条件全量重跑**。`lua/vcssign/attach.lua:231` 的 `M._render`
永远 `nvim_buf_get_lines(0,-1)` + 最多两次 `vim.text.diff` + `signs.place`×2，即使 `st.base_text`
与 buffer 内容都没变。§2.2 最直接的两个证据：`FocusGained` 无磁盘变化 → 每 buffer 6 进程 2 渲染
零差异；**一次普通编辑 → 3 个进程**——纯 buffer 编辑根本不需要碰 git（基线没变，重 diff 本地
内存里就够了）。
→ 建议：缓存 `(基线指纹, changedtick)`，两者都没变直接 return。这是**改动最小、收益最直接**的
一条（几行代码，`FocusGained` 那 120 个进程立刻归零），列为 §6 第 1 步。

> **状态：已修（M7 步骤 1），前/后实测见 §2.4。** 实际不是「几行」：要一个零进程的基线指纹，
> 就得多给适配器一个可选钩子 `baseline_stamp(root)`（stat `.git/index`+`HEAD`+分支文件，或
> `.svn/wc.db`），拿不到就返回 `nil`、退回原行为。指纹 = `changedtick` + 基线 stamp + 渲染
> 相关配置（`signcolumn`/`word_diff`/`deleted_preview`/`signs`/`diff`）。svn 一并受益。

**P0-5 首次 attach 重复探测 root**。§2.2 的进程序列里前两个 `rev-parse --show-toplevel`：
一个来自 `registry.detect_async`（`lua/vcssign/vcs/init.lua:139`），一个来自 `Repo:_do_refresh`
的存活探测（`lua/vcssign/repo.lua`），答案必然相同。
→ 建议：`manager.attach` 拿到权威 root 后直接喂给 `Repo`（`has_loaded = true`，跳过首轮探测），
每仓库省 1 进程。近 1 行级别的改动。

### P1 · 动作层的重复工作

**P1-1 stage 类动作后的双重刷新（git；svn 只剩 revert 路径）**。`lua/vcssign/actions.lua:370-371`（`stage_hunk`）与
`:403-404`（`unstage_hunk`）同时调 `attach.refresh(ctx.bufnr)`（重拉基线 + 2×diff + 2–3 进程）
**和** `t.repo:refresh_now()`（1 个 `rev-parse`，其 `on_update` 又会触发 buffer 刷新——§2.2
`FocusGained` 每 buffer 恰好 2 次渲染就是「两条路径都在跑」的直接证据）。
`actions.lua:367-369` 的注释解释了为什么要立刻刷（「下一个 hunk 动作要读屏幕上的层，不能等
200ms debounce」）——但**两条路径只需留一条**：留 `attach.refresh`（同步满足注释诉求），
`refresh_now` 交给去抖（或者反过来，取决于 §7 待验证项 5 的实测）。
`reset` / `commit` / `stage` / `unstage` 的 `repo:refresh_now()`（`actions.lua:442/478/481/616`）
同理可核一遍。

**P1-2 `has_staged_change` 两次 `show` 全文比较（仅 git）**。`lua/vcssign/actions.lua:565-576` 拉 index
与 HEAD 两份**全文**再字符串比较。`git diff --cached --quiet -- rel`（或 `git status` 缓存，
见 P0-1）一次就能回答，还省两份全文的内存。svn 无 index，此函数不会被调到。

**P1-3 行内 blame 每次编辑都全文件 blame（git 可带 `-L`，svn 不能）**。缓存 key 含 `changedtick`
（`lua/vcssign/blame.lua:179`），而 `blame_for`（`lua/vcssign/blame.lua:174`）从不传
`from/to` → 每次按键 debounce 后整文件 `git blame --line-porcelain`（43 ms + 全文件解析）。
适配器早就支持 `-L from,to`（`lua/vcssign/vcs/git.lua:283` 的 `M.blame`），`options_key`
（`lua/vcssign/blame.lua:161`）也已把 `opts.from` 纳入 key——**只差 `blame_for` 把当前行号带上**。
再把缓存从「changedtick 全失效」改成「按行 + 按基线指纹」，编辑未提交内容不再让所有行失效。
**svn 走不了 `-L`**：`svn blame` 没有行窗口选项，`lua/vcssign/vcs/svn.lua` 的 `M.blame` 只能
`_opts` 收下后忽略（全文件 `--xml`，实测 74.7 ms；适配器注释里另有 200 行 43.9 ms 对纯文本
141.1 ms 的对比）。svn 侧收益**只能**来自缓存策略（按 changedtick → 按行 + 基线指纹），这也是
这条改动对两类 VCS 都值得做的原因。

**P1-4 `get_by_path` 线性扫描 + `relpath` 重复归一化**。`lua/vcssign/repo_manager.lua:82-91`
对每个 repo 一次 `base.relpath`，而 `relpath` 对**两个参数**都各跑一遍
`fnamemodify(':p') + vim.fs.normalize`（`lua/vcssign/vcs/base.lua` 的 `M.relpath`）。
实测 10 root = 0.25 ms——**当前规模完全可接受**，列为低优先级：真要做就按 root 前缀建索引表
或缓存 `path → repo` 映射，并让 `relpath` 只归一化未归一化的一方（manager 的 root 本就已归一）。

### P2 · 微项（都有测量；本质是「顺手改」，不单独立项）

| 编号 | 位置 | 内容 | 实测 |
|------|------|------|------|
| P2-1 | `lua/vcssign/signs.lua:255` | 每个 added 行一个 extmark：未跟踪 5000 行 = 5000 extmark | 3.8 ms + 内存；可只标首/末行或在超长未跟踪文件截断 |
| P2-2 | `lua/vcssign/signs.lua:227-232` | `signs.place` 内 `config.get()` ×8 | 一次取局部变量即可 |
| P2-3 | `lua/vcssign/attach.lua:240,252` | `diff.normalize(st.base_text)` 算两次 | 一个局部变量 |
| P2-4 | `lua/vcssign/attach.lua:354` | `signs.define_highlights()`（约 30 个 `nvim_set_hl`+`nvim_get_hl`）每次 attach 重建 | 0.17 ms/次；加模块级 `defined` 标志 |
| P2-5 | `lua/vcssign/util.lua:38` | `emit` 用 `vim.deepcopy` 拷函数列表 | 0.0009 ms，性能可忽略；**语义**上应为浅拷贝（deepcopy 函数表既贵也无隔离意义） |
| P2-6 | `lua/vcssign/diff.lua:71` vs `lua/vcssign/config.lua:170` | **文档漂移**：diff.lua 注释说「`config.diff.linematch` 默认 `true`」，config.lua 实际 `false`（且注释里带着实测：500 行 1.1s / 2000 行 69s / 5000 行 OOM） | 改注释，防止有人「顺手」打开它 |

## §3.5 按 VCS 的适用矩阵（git / svn）

本插件默认同时支持两类系统（`config.systems = { 'git', 'svn' }`），但两者的能力面不同，
所以上面每条发现的「能怎么修」也不同。**「浪费」本身在两类 VCS 上都存在**（每次渲染都 spawn、
无差别重跑整文件管线），所以 P0 级的四条修法（P0-1/3/4/5）两端都吃；但有**三条修法在 svn 上
根本不存在**（P0-2 的 blob 批协议、P1-2 的 staged 比对、P1-3 的 `-L`），它们只能换成别的修法
或只能靠缓存——M7 排期不能拿 git 的收益去算 svn。

| 发现 | git | svn | 差异要点 |
|------|-----|-----|----------|
| P0-1 每渲染固定进程 | 3（`ls-files`+`show`+`show HEAD`） | 2（`info`+`cat -r BASE`；`staged_signs=false` → `load_head` 跳过，`attach.lua:145`） | svn 进程少但单价高：**≈144 ms vs git ≈129 ms**（§2.2），所以 svn 更需要 P0-1 的 status 缓存 |
| P0-2 常驻 blob 进程 | ✅ `cat-file --batch` | ❌ 无等价协议（`svn cat` 多目标无分隔符） | svn 的收益改由「干净文件不取基线」实现 |
| P0-3 `changed_paths` | ✅ **已修** | ✅ **已修** | 锚点不同（`.git/index`+HEAD / `.svn/wc.db`），代码同一条；实测外部改写一个文件 git 20→1、svn 6→1 个 buffer（§2.5）；svn 的 watch 落点见 S1 |
| P0-4 渲染短路 | ✅ **已修** | ✅ **已修** | 同一代码路径，**双收益**；实测 git 121→1 进程、svn 25→1（§2.4） |
| P0-5 首次 attach 去重 root | ✅ `rev-parse`×2 | ✅ `info --show-item wc-root`×2（实测首次 attach 的 3 次 `info` 里 2 次问的是同一件事） | 同一条修法 |
| P1-1 stage 双刷新 | ✅ `stage_hunk`/`unstage_hunk` | ⚠️ 无 staging（`actions.lua:162` 直接 `refuse`），但 `reset_hunk`→`revert` 后的 `repo:refresh_now()`（`actions.lua:442`）是同一个模式的残留 | svn 侧只核 revert/reset 路径 |
| P1-2 `has_staged_change` | ✅ | ❌ 无 index（函数不会被调用） | git-only |
| P1-3 blame `-L` | ✅ 支持 `-L` | ❌ `svn blame` 无行窗口（适配器 `_opts` 已忽略） | svn 只能靠缓存，见 P1-3 |
| P1-4 `get_by_path` 线性 | ✅ | ✅ | 与 VCS 无关 |
| P2-1…P2-5 | ✅ | ✅ | 与 VCS 无关（P2-6 文档漂移跨两者） |

### svn 专属发现

**S1 `.svn` 的递归 watch 落点与句柄数（待验证，中低优先级）。**
`lua/vcssign/repo.lua:364` 是 `self.system.metadata_dir and self.system.metadata_dir(self.root)`，
而 svn 适配器**没有** `metadata_dir`（只有 `lua/vcssign/vcs/git.lua:124` 有），于是
`metadata_path = marker_path = <root>/.svn`，再按 `RECURSIVE_FS_EVENT`（非 Linux 为真）**递归**
监听。svn 1.7+ 的 `.svn/pristine/` 按 sha1 首字节**分片到最多 256 个子目录**，在 Windows/macOS
上就是每仓库几百个 `uv_fs_event_t`。功能上没问题（`wc.db` 就在 `.svn/` 下，非递归也能看见），
但**句柄数**这件事没人量过：本文的 fixture 只有 4 个分片（文件太少），需在 1000+ 文件的真实 wc
上数 `helpers.uv_count()` 才有结论（列为 §7-7）。修法很轻：给 svn 加
`metadata_dir = function(root) return root .. '/.svn' end` 并让 `_init_watch` 对 metadata 只做
非递归监听（`pristine/` 的变化与「基线上限」无关）。

**S2 `svn info` 接受多目标——不换接口就能把 N 次进程压成 1 次（两类 VCS 都有类似物）。**
实测：`svn info` 带 6 个目标 = **54.2 ms**，而单目标 82.5 ms，即**多问 5 个文件几乎不要钱**。
同一条思路对 git 也有（`git ls-files -- a b c`），但 `--error-unmatch` 只要有一个未跟踪就整体
非零、得按输出逐行判定，比 svn 麻烦。价值：**不需要先做 A1 的 `status` 原语**，只要把
`load_base` 里相邻 buffer 的 `is_tracked` 合并成一次调用，就能在 20 文件的场景里先砍掉十几个进程
——可作为 P0-1 完整落地的**过渡步**（尤其 svn，那里 `info` 是最贵的一条）。

**S3 svn 的 `apply_patch` 每个 hunk 写一个临时文件（不要「顺手统一成 stdin」）。**
`lua/vcssign/vcs/svn.lua` 的 `M.apply_patch` 用 `vim.fn.tempname()` + `fs_open/fs_write/fs_close`
把补丁落盘，因为 **svn 1.14.5 不接受 stdin 补丁**（报 `svn.EXE: invalid option:`，适配器头注释
有实测记录）；git 侧走 stdin。文件系统开销在 µs 级，不构成性能项，但 M7 如果重排 patch 层，
**不能把两者统一成 stdin**——这是能力差异，不是实现瑕疵。

## §4 架构层结论

**A1 `VcsSystem` 缺批量原语——P0-1/P0-3 无法在上层修复的根因。**
`capabilities`（`lua/vcssign/vcs/base.lua`）只有 `stage/staged_signs/revert_hunk/blame/show_rev/commit`，
接口没有 `status(root, cb)`。§2.1 的「整仓库批量与单文件同价」在**两类 VCS 上都成立**
（git 44 vs 43 ms，svn 63.9 vs 82.5 ms），所以加 `status` 是双收益：
git 用 `status --porcelain=v2 -z`，svn 用 `svn status --xml`（列 7 tree conflict / 列 5 switch 的
解析经验在 M1 附录 A1/A2，但形态要从固定列平移到 XML 属性，见 §7-4）。之后「仓库级缓存 +
buffer 级查询」才可能实现。`read_blobs`（P0-2）同理是接口级缺口，**但它只对 git 有实现**
（svn 无 blob 批协议，只声明 `capabilities.batch_blobs = false` 即可，不阻碍接口设计）。

**A2 D38（取消 per-file 状态缓存）需要用新数据重估。**
D38 的收益是「去掉一层同步 cache 的失效复杂度」，代价经本文实测是 **O(buffers)×(2–3) 进程 /
每个仓库事件 + 每 buffer 每渲染 2–3 进程**。在 43–82 ms 的 spawn 常数下这个取舍明显亏。
可行折中（不推翻 D38 的精神，只收窄它）：**缓存「状态」，不缓存「内容」**——谁被跟踪 / 谁有
staged 变更由批量 `status` 缓存（失效面小：只在索引/HEAD 变动时失效，而这恰好是 fs_event 能直接
告诉我们的，见 A3）；基线内容仍每次现拉，靠 P0-2 的常驻进程（git）/ 「干净文件不取基线」
（svn，见 P0-1）把它变廉价。这样既没有「内容缓存与磁盘不一致」的旧问题，也消掉了大部分进程。

**A3 `Repo → attach` 缺「哪个文件变了」的通道（已修，M7 步骤 2）。**
原状：`repo:on_update(fn)` 是无参通知，`attach` 只能全员刷新（P0-3 的另一半）。现在通道有了：
`FocusGained`（无事件 → 空集 → 一个 buffer 都不进）、`BufWritePost` / 外部 `git checkout`
（svn：`svn revert` / `svn up`）都能精准定位到 buffer；索引 / `wc.db` 变了仍是仓库级失效
（喂 A2 的状态缓存），工作区文件变了才走 buffer 级。实测见 §2.5。

**A4 可测性缺口：进程数没有回归约束。**
进程数是本插件最重要的性能指标，但当前 260 个用例没有一条约束它（时间断言在 CI 上也不稳）。
建议把 §1 的探针固化为 spec：打桩 `exec.run` 计数 + `attach._render` 计数，断言
「打开 N 个文件 ≤ k 进程」「`FocusGained` 无磁盘变化 → 0 个 `show`/`cat`」「纯 buffer 编辑 → 0 进程」。
计数断言跨平台稳定，能防未来回归——本表的验收数字见 §6。**必须 git/svn 各一套**（同为
`.lua` 文件、只换 fixture 与断言数字），否则「svn 无 staged 层」这类能力差异会被 git-only 的
断言悄悄漏掉。**P0-4 的那一半已经落了**：`test/attach_spec.lua` 的 `count_procs`（不过滤命令，
每次 `exec.run` 计一）+ 4 例断言；以后的步骤照这个样子往同一个 helper 上加。

**A5 模块级单例状态**（`attach._bufs` / `blame._bufs` / `signs._ns` / `manager._by_root`）。
单实例下没有问题，只是决定了「同一 nvim 内无法干净 dispose 后重测」。纯整洁度，**不必动**。

## §5 明确不优化（有测量，防止浪费精力）

| 项 | 证据 | 结论 |
|----|------|------|
| `vim.text.diff` 本身 | 40000 行全改写 8.1 ms（§2.3）；`linematch=false` 的实测见 `config.lua:164-170` | 已经够快；`linematch=false` 是**对的**（D39 相关），别开 |
| staged 层的第二次 diff | +0.4 ms（2000 行、2%） | 不是问题，别为省它搞增量 diff |
| `worddiff` 逐字符 tokenizer | opt-in（默认关）；开启后 200 对 2.2 ms | 不值得重写 |
| `util.emit` 的 deepcopy | 0.0009 ms | 性能上忽略；要改是语义问题（P2-5） |
| `define_highlights` 重复执行 | 0.17 ms/attach | 加标志位是顺手改（P2-4），不是优化项 |
| `get_by_path` 线性扫描 | 10 root 0.25 ms | 当前规模不构成问题（P1-4 备档） |
| 已禁用的 preview 仍被调用 | 0.001–0.002 ms（纯 namespace 清空） | 开销为零，保留「渲染一致性」的设计反而正确 |
| svn 的 `blame --xml` 整文件（74.7 ms） | svn **没有**行窗口选项，`-L` 无法用 | 不是「不想优化」而是「优化不了」；svn 侧只能靠缓存（P1-3） |
| svn 的 `apply_patch` 临时文件 | µs 级 fs 操作；svn 1.14.5 不接受 stdin | 能力差异，不是瑕疵（S3） |

## §6 推进顺序（M7 候选清单）

按「改动小 → 收益大」排：

- [x] **1. P0-4 渲染短路**——已落地（§2.4）：`FocusGained` 121 → 1 进程、同步 80.1 → 3–5 ms
      （svn 25 → 1 / 72.2 → 0.6 ms），纯编辑 6 → 0；新增可选适配器钩子 `baseline_stamp(root)`
      作为基线指纹（git: `.git/index` + `HEAD` + 分支文件；svn: `.svn/wc.db`），拿不到返回 `nil`。
- [x] **2. P0-3 `changed_paths` 通道**——已落地（§2.5）：`Repo:on_update(fn, changed)` 三态
      （集合 / `nil` / 空集），`attach` 侧按 `changed[st.path]` 过滤；外部改写一个文件从
      git 20 buffer / 61 进程降到 1 / 1，`FocusGained` 的重复渲染 40 → 20（svn 12 → 6）。
- [ ] **3. P0-5 去重首轮 `rev-parse`**——`manager.attach` 把权威 root 喂给 `Repo`。
- [ ] **4. P0-1 状态缓存（跨 VCS，最高优先）+ P0-2 `read_blobs`（仅 git）**——动 `VcsSystem` 接口
      （A1/A2）：git `status --porcelain=v2 -z` + `cat-file --batch` 常驻；svn `status --xml`
      （干净文件直接不取基线）。可先落 **S2 的过渡步**（多目标 `svn info` / `ls-files`）拿到一半收益。
- [ ] **5. P1 动作层三处**——stage 双刷新二选一（先做 §7-5 的探针；svn 侧只核 revert/reset 路径）、
      `has_staged_change` 改 `--cached --quiet`（仅 git）、blame 带 `-L`（git）+ 按行缓存（两类都受益）。
- [ ] **6. A4 探针固化**——`test/exec_spec` 加进程计数断言；§6 每步收尾时更新本文实测表。
- [ ] P2 六项在顺路提交里捎带（尤其 P2-6 的文档漂移——独立一个 `docs(diff)` 提交也行）。

**验收断言建议**（A4 固化时用计数写，不写毫秒）：

```
打开同仓库 20 个文件   ≤ 30 进程（当前 git 141）
FocusGained（磁盘不变） 0 进程（当前 git 120 / svn 13）→ ✅ 已达到下限「每仓库 1」（§2.4：git 1 / svn 1）
FocusGained 渲染进入次数     ≤ buffer 数（原 git 40 / svn 12）→ ✅ git 20 / svn 6（§2.5）
外部改写 1 个文件             1 个 buffer / ≤ 2 进程（原 git 20 buffer、61 进程）→ ✅ 1 / 1（§2.5）
纯 buffer 编辑          0 进程（当前 git 3 / svn 2）    → ✅ 0 / 0
首次 attach 单文件      ≤ 3 进程（当前 git 5 / svn 4）
干净文件（status 无记录） 0 个 show/cat（当前 git 3 / svn 2）
stage_hunk 一次         ≤ 6 进程（当前双路径 ≈7；svn 无此动作）
```

两类 VCS 都要有对应断言——**svn 的计数天然比 git 少一个，别把 git 的数字写死成通用门限**。

## §7 待验证项（P0 动工前要补的探针）

1. **Linux/macOS 的 spawn 单价**——P0-2 常驻进程的收益会缩小多少（spawn 便宜的平台上
   `cat-file --batch` 仍省进程数，但毫秒收益变小）。
2. **`cat-file --batch` 在真实大仓库 + 并发请求下的行为**——本文只实测了启动（47 ms）；
   长驻进程的排队、`vim.system` 长驻对象的生命周期（`dispose` 时怎么收）要单独探。
3. **`git status --porcelain=v2 -z` 解析成本**——v1 的 `-z` 双段解析 M1 做过
   （`01-vcs-adapter.md` §4.2 / 06 附录 A1），v2 字段不同；复活旧解析比新写便宜，但要对表。
4. **svn `status --xml` 的冲突形态**——基本形态已实测（§2.1：`item="unversioned"` /
   `item="modified"`、1369 字节/6 文件），剩下是 tree conflict（列 7 C）/ switch（列 5 S）在 XML 里
   长什么样：用 `temp/svn-conflict-a`、`temp/svn-switch` 两个既有 fixture 探（06 附录 A2 的固定列
   经验要平移成 XML 属性）。
5. **`attach.refresh` 与 `repo:refresh_now` 的双路径**——`FocusGained` 每 buffer 2 渲染
   已是「两条都在跑」的证据，但 stage_hunk 场景删哪一半、删后「`hs`→`hu` 连按」是否仍即时，
   要在 `temp/git-repo` 上实测（`actions.lua:367-369` 注释是这条的约束）。
6. ~~**P0-4 的指纹取法**~~——**已解决（M7 步骤 1）**：基线侧不查 `git status`、不算内容 hash，
   直接 stat 元数据——git 是 `.git/index` + `HEAD` + `HEAD` 指向的分支文件（提交只改分支文件，
   `HEAD` 本身字节不变，只 stat `HEAD` 会漏），svn 是 `.svn/wc.db`（update/switch/revert/add/commit
   都重写它）。因此**不再依赖 P0-1**，§6 第 1、4 步的顺序可以任意。配置侧另加一个「渲染相关
   选项」指纹（`config.setup` 换表 + `word_diff` 原地翻转都要能被看见）。
7. **svn 大工作副本的句柄数**（S1）——在 1000+ 文件的 wc 上数 `helpers.uv_count()`（`repo_spec`
   已有按 `vim.uv.walk` 断言句柄的写法可抄），确认 `.svn` 递归 watch 是否真的要几百个句柄；
   若成立，`metadata_dir` 钩子 + 非递归 metadata watch 是个十行级的修法。
8. **多目标合并的上限**（S2）——`svn info` / `git ls-files` 单次能安全带多少路径？
   Windows 的 argv 上限（约 32K 字符）在深层路径下可能几十个文件就碰到，需要分块策略。

## §8 不做什么（约束沿用 D46 / 07 §12）

- **不引入 async 框架**——P0-2 的常驻进程用「长驻 `vim.system` + 回调队列」实现，仍是回调链 +
  错误优先契约（D19 不动）。
- **不新增依赖**——全部建议只用 git/svn 自带子命令。
- **不做 per-hunk 增量 diff**——§2.3 已证 `vim.text.diff` 足够快，P0-4 的短路比增量算法便宜得多。
- **不缓存基线「内容」跨变更窗口**——D38 教训；只缓存「状态」（A2）。
- **不动 P2 里标注「不必动」的项**（§5 全表）。
