# backlog：CI 与测试卫生（`testing/`）

**状态**：`[ ] 未开始`

**出处**：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md` §4（CI 一段）
与 `loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md` §11.5（`svn blame` 大文件耗时探针）。

**为什么记下来**：CI 当时写不了（本机没有 GitHub 远端，写了也无法验证）；`svn blame` 大文件的
耗时只有 200 行数据，不构成结论。两件都不是「不做」，是「等条件」。

---

## 一、CI（`.github/workflows/ci.yml`）

> 原文（`05 §4` 末条）：

- CI（`.github/workflows/ci.yml`）：**仍未做**（backlog 不变）——本机没有 GitHub 远端，写了也无法验证。
  接入时的步骤：ubuntu（`apt install subversion` + `luarocks install luacheck`）与 windows 两个 job，
  跑 `make format-check` / `make lint` / `sh scripts/run_tests.sh`；svn 不可用时 `test/run.lua` 打印 SKIP 并继续。

**现状**：仓库里没有 `.github/` 目录（截至本次迁移）。

### 验收要点

| 项 | 验收要点 |
|---|---|
| 两个 job | ubuntu-latest 与 windows-latest 各一个；矩阵（或两个独立 job）都要跑 |
| ubuntu 依赖 | `apt install subversion` + `luarocks install luacheck`；`scripts/tools.sh` 把工具钉版本下到 `deps/` |
| windows 依赖 | svn 不可用时 `test/run.lua` 打印 SKIP 并继续（不能因此判失败）；luacheck 用 `deps/` 里的预编译 exe |
| 三个命令 | `make format-check` / `make lint` / `sh scripts/run_tests.sh` 全绿（或按上面的 SKIP 规则） |
| 真实可验证 | 必须能在真实 PR 上跑起来（有远端、有结果），否则等于没做 |

## 二、`svn blame` 大文件耗时探针（`07 §11.5`）

> 原文（`07 §11` 第 5 项）：

- **`svn blame` 大文件（> 1k 行）耗时未测**（本次只有 200 行数据）。

### 验收要点

| 项 | 验收要点 |
|---|---|
| 探针数据 | 造一个 > 1k 行的 svn fixture，实测 `svn blame` 的端到端耗时（含进程启动） |
| 结论 | 得出「是否需要在行数上限之上再加一道 `svn blame` 的阈值 / 缓存」的结论；若需要，配置项默认值有实测依据 |
| 落地 | 结论写回 `loop/knowledge/vcs/svn-output-formats.md` 或本任务文档；若加阈值，补 `blame_spec` 用例 |

## 三、跨 spec 的 `guarded` / `collect` 复制

> 与 `07 §10` 第 8 项同源（「11 份 spec 各自抄了一份清场包装，该收进 `test/helpers.lua`」）。

**现状**（截至本次迁移，已比原文的 11 份更多）：13 份 spec 各自定义了 `local function guarded`
（`actions_spec` / `attach_spec` / `autocmds_spec` / `blame_spec` / `cli_spec` / `diff_spec` /
`hunk_spec` / `nav_spec` / `preview_spec` / `repo_spec` / `revdiff_spec` / `signs_spec` /
`worddiff_spec`），`actions_spec.lua` 另有一份 `collect`。

### 验收要点

| 项 | 验收要点 |
|---|---|
| 收拢 | `guarded(fn)`（必要时连 `collect`）移入 `test/helpers.lua`，13 份本地副本删除 |
| 行为不变 | 清场语义一致：失败也清 `touched` 缓冲区 / `attach.forget_all()` / `manager.dispose_all()` / `config.setup({})` |
| 全绿 | `make test` 全绿（当前 260 用例），用例数不因重构减少 |
