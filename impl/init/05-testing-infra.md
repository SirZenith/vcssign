# 05 · 测试仓库（temp/）、测试脚手架、lint / CI / 文档（P4，与 01–03 并行推进）

> 用户已指定：测试用的 git / svn 仓库放在**当前项目目录下的 `temp/`**。
> 本次规划会话处于只读沙箱（bash 全被拦截），无法实际创建 `temp/`，
> 因此本文件给出**幂等的仓库生成脚本**作为 M0 步骤，任何环境跑一次即可复现。

## 0. 前置（build 阶段第 0 步，涉及 impl/ 之外，需切 build agent 或用户手动）

1. 在仓库根 `.gitignore` 追加：
   ```
   /temp/
   deps/
   .nvimlog
   ```
   （`impl/` 目录是否入库由用户决定——建议入库，作为规划文档。）
2. `git worktree add` 等 fixture 依赖已就绪即可开始。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `scripts/make_test_repos.sh` | 幂等生成 `temp/` 下全部测试仓库 |
| `scripts/run_tests.sh` | headless nvim 跑 test spec |
| `test/preload.lua` | spec 前置 require（参考 gitsigns `test/preload.lua`） |
| `test/helpers.lua` | 断言 / 等待异步收敛 / 仓库 fixture 操作 |
| `test/vcs_git_spec.lua` … | 按 00 §3 列表的 spec |
| `stylua.toml` / `.luacheckrc` / `Makefile` | 工程工具链（gitsigns 同款） |

## 2. temp/ 测试仓库（scripts/make_test_repos.sh）

幂等：每步 `[ -d x ] || ` 判存。git 需设置 `user.email/user.name`（local config，避免依赖全局）。

### 2.1 `temp/git-repo`（主 fixture）

```sh
git init -q temp/git-repo && cd temp/git-repo
git config user.email t@t && git config user.name t
git config core.quotepath on          # 刻意保留引号场景？不需要: 适配器加 -z,引号不会出现; 保留 off 更真实
echo base > base.txt
echo 中文测试 > "文件 名.txt"          # 空格 + 非 ASCII 路径用例
git add -A && git commit -qm init
# 工作区状态矩阵:
echo mod > base.txt                    # modified (local M)
echo new > new.txt                     # untracked (??)
git add new.txt                        # added (upstream A) — staged
git add base.txt                       # staged modify
mkdir -p sub && echo x > sub/x.txt && git add sub/x.txt
git mv "文件 名.txt" renamed.txt       # staged rename (R)
git rm -q --cached base.txt 2>/dev/null || true   # 交错组合按需
```

状态矩阵目标（spec 断言的期望集合）：

| 状态 | 造法 |
|------|------|
| `local M` | 改工作区文件 |
| `upstream A` | `git add` 新文件 |
| `upstream M + local M` | add 后再改工作区 |
| `upstream R`（rename + orig_path） | `git mv` |
| `?? untracked`（含空格/中文路径） | 未 add 的新文件 |
| `U conflicted` | `git merge` 制造冲突（单独一个 `temp/git-repo-conflict`，避免主 fixture 污染） |
| worktree root 检测 | `git worktree add ../git-worktree -b wt`（01 §7 回归点） |

### 2.2 `temp/svn-repo`

svn 无「本地 init」，需要 `svnadmin`（环境有 svn 客户端，svnadmin 一般同装；脚本检测缺失则跳过并打印 SKIP 标记，spec 按标记跳过）：

```sh
svnadmin create temp/svn-server
svn mkdir -q --parents file:///"$PWD/temp/svn-server"/trunk -m init   # URL 形式 Windows 下用 file:///D:/... 三斜杠 + 盘符
svn co -q file:///"$PWD/temp/svn-server"/trunk temp/svn-repo
cd temp/svn-repo
echo base > base.txt && svn add -q --force . && svn commit -qm init
# 状态矩阵:
echo mod > base.txt                    # M
echo prop > prop.txt && svn add prop.txt   # A
svn rm -q --keep-local old.txt         # ! missing (版本化文件被 rm) — 先 commit 一个 old.txt
echo untracked > new.txt               # ?
svn propset -q myprop v base.txt       # 属性修改 M(第2列)
```

状态矩阵目标：`M / A / D / ! / ? / 属性修改 / R(replaced)`（`svn rm` + `svn add` 制造）+ `--show-item wc-root` root 断言。

### 2.3 `temp/nested`（嵌套用例）

`temp/nested` 为 git 仓库，其中 `inner/` checkout 了上面的 svn server（git 里 ignore 掉 `inner`）→ 01 §7.4 的系统切换用例。

### 2.4 退出码矩阵

`temp/` 各仓库全部是「已知状态」的——spec 断言状态**集合与每条 path 域值**，而不是数量（增删 fixture 不破坏断言用「expected ⊆ actual」集合断言）。

## 3. spec 编写与运行

风格对齐 gitsigns `test/`（`gs_helpers.lua` + `*_spec.lua` + `make test FILTER=`）：

- 不引入 gitsigns 用的 `nvim-test`（它克隆 nvim 二进制 + 依赖 bash 工具链，Windows 成本高）。初版自研轻量运行器：
  - `scripts/run_tests.sh`：`nvim --headless -u test/minimal_init.lua -l test/preload.lua -c "lua run_spec('$1')"`；每个 spec 文件是一个返回 `{{name, fn}}` 列表的模块；preload 提供全局 `ok/eq/check(实际, 期望)` 断言收集器；结束时汇总 exit code。
  - 输出 `TAP` 风格（`ok 1 - git parse: rename` / `not ok …`），exit code 非 0 即失败——CI 友好。
- **异步等待**（02 的管线全是回调）：`helpers.wait_for(pred, timeout_ms)`（uv timer 轮询 20ms 间隔，gitsigns 测试里等待刷新收敛的同款思路）。
- 每 spec 用例自带临时可写目录（复制 `temp/git-repo` → `temp/.work/<spec-name>`，结束后删除）——**fixture 只读，写入发生在副本**，保证矩阵可复现、多次运行幂等。
- spec 清单（对应各计划文件的验收标准）：
  - `vcs_git_spec`：01 §7.1 + `-z` 解析（空格/中文/rename orig_path）
  - `vcs_svn_spec`：01 §7.2 + root `--show-item wc-root`、`<1.9` 降级用例（mock `svn --version` 输出）
  - `repo_spec`：02 §5.1–5.5（去抖收敛、`.git/index` 监听、dispose 句柄清零——`vim.loop` 事件句柄计数）
  - `renderer_spec`：03 §6 排序/分组/双 sign 位/extmark 清理（`nvim_buf_get_extmarks` 断言）
  - `sidebar_spec`：04 §6 全链路（headless 下 `nvim_open_win` 浮窗路径跳过，right/left split 路径可测）
  - `actions_spec`：stage/unstage/commit 全链路（副本仓库上真实跑命令）

## 4. lint / format / CI

- `stylua.toml`：gitsigns 同款（2 空格、单引号、100 列——与 gitsigns `.stylua.toml` 一致，本仓风格统一用它）。
- `.luacheckrc`：globals = `vim`，`impl/` 排除。
- `Makefile`（bash 可用环境；Windows 下用 `scripts/*.sh` 直接跑，git-bash 就绪）：
  - `make test [FILTER=pattern]` → `scripts/run_tests.sh`
  - `make format` / `format-check` → stylua
  - `make lint` → luacheck
- CI（`.github/workflows/ci.yml`，backlog 可后置）：ubuntu + windows matrix 跑 `make format-check` + `run_tests.sh`；svn fixture 在 CI 装 `subversion` 包；Linux 的 fs_event 非递归限制不影响（监听 root + `.git/.svn` 顶层在 Linux 可用）。

## 5. 文档

- `doc/vcssign.txt`：初版手写（安装、配置表、命令表、状态符号表、架构一节引用 00–04 计划）。
- 后期：`scripts/gen_help.lua` 从 `config.lua` 的 schema 表生成配置段（gitsigns `make doc` 模式，backlog）。

## 6. 验收标准

1. 全新克隆后：`scripts/make_test_repos.sh` 幂等跑两次，第二次全 skip；`temp/` 结构与 §2 矩阵一致。
2. `scripts/run_tests.sh` 全绿（svn 缺失环境打印 `SKIP svn` 并不失败）。
3. `stylua --check` / `luacheck` 零输出。
4. spec 失败注入（改坏一个断言）→ TAP 输出定位到用例名，exit code 1（CI 可用性验证）。
