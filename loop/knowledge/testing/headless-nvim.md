# headless nvim 测试基建（本项目实测）

> 知识文档（`loop/knowledge/`）。来源：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md` §3–§5、§7。
> 原文抽取，未做改写。

**要点**：自带 TAP runner（`test/run.lua`）+ 阻塞式 `helpers.wait`；断言尽量用 `screenstring` 读**屏幕单元格**
（能抓到 sign 列的真实排布）；工具**钉版本**下到 `deps/`（gitignored），`LUA_FILES` 走 `git ls-files`
（未 `git add` 的新文件会漏检）；headless 里 `:helptags`/`:DirChanged`/`CursorMoved` 等行为与 UI 模式不同。

---

*来源：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md`，原文 `## 3. spec 编写与运行`*（标题层级已下移一级）

### 3. spec 编写与运行

风格对齐 gitsigns `test/`（`gs_helpers.lua` + `*_spec.lua`）：

- 不引入 gitsigns 用的 `nvim-test`（它克隆 nvim 二进制 + 依赖 bash 工具链，Windows 成本高）。
  自研轻量 runner（**已落地**）：
  - 入口：`scripts/run_tests.sh [spec ...]` → `nvim --headless -u NONE -l test/run.lua`。
  - `test/run.lua` 自己算插件根目录并把 `lua/?.lua`、`lua/?/init.lua`、`test/?.lua` 填进 `package.path`，
    因此不依赖 cwd，也不需要 `minimal_init.lua`。
  - 每个 spec 文件是一个 `require` 得到的**返回 `{{name, fn}}` 列表**的模块；断言失败即 `error`，
    runner 用 `pcall` 捕获 → 打印 `not ok N - <spec>: <case>` + 缩进错误信息。
  - 全局断言 `ok(cond, msg)` / `eq(actual, expected, msg)`（`vim.deep_equal` 比较）/ `check`（同 `ok`）。
  - 缺外部命令时打印 `# SKIP <spec> (<bin> not found)` 且不计为失败（`REQUIRES` 表）；
    `temp/` 不存在则直接退出 1。
  - 最后打印 `1..N` 汇总，有失败即 `cq`（exit 1）——CI 友好。
  - **结果写 stdout（`io.stdout:write`）而不是 `print`**：headless 下 `print` 走 **stderr**，
    会与插件自己的 `vim.notify` 日志粘成一行（实测把两条 `ok` 拼在一起，导致行数统计出错），
    而且 `2>/dev/null` 会把结果一起丢掉。插件日志留在 stderr，结果留在 stdout。
- **异步等待**：`helpers.wait(fn, timeout)`——阻塞式 `vim.wait`，把回调的 `cb(err, ...)` 收集后原样返回，
  于是 spec 可以写成同步顺序代码。另有 `helpers.wait_for(pred, msg)` 用于「事后某个状态应出现」
  的断言（如「缓存里应出现这个文件」）。
- **可变的临时仓库**（M2 起）：`helpers.git_repo(name)` / `helpers.svn_checkout(name)` 在
  `temp/_spec/<name>` 下现场建仓（`git init` 或 `svn co file:///.../svn-server/trunk`），
  `helpers.cleanup()` 在 runner 末尾删除整个 `temp/_spec`。
  **共享 fixture 仍是只读的**：M1 spec 断言它们精确的状态矩阵，若在 `temp/git-repo` 里
  `git add` 一次，下一次跑套件就会失败。
- **uv 句柄计数**：`helpers.uv_count('fs_event'|'timer')` 遍历 `vim.uv.walk`——02 §5.4 的
  「dispose 后句柄清零」就是用它断言前后相等（比只查内部字段更接近真实泄漏）。
- **回调里不要断言**：管线的 waiters/订阅者由 `pcall` 隔离（02 §3.3），断言会被当作
  “callback failed” 记日志而**不会**让用例失败。spec 把结果写进变量、在用例体内断言。
- spec 清单（对应各计划文件的验收标准，✅ = 已落地）：
  - ✅ `status_type_spec`：枚举三件套不变量、未知状态的降级
  - ✅ `config_spec`：list 整体替换（含嵌套层）、空表按 dict 合并、不污染 defaults
  - ✅ `vcs_git_spec`：01 §7.1 + §7.3 + `-z` 解析（空格/中文/rename orig_path/缺 orig 容错）
        + **stale marker 不当 root**（空 `.git` 目录、指向不存在 gitdir 的 `.git` 文件）
  - ✅ `vcs_svn_spec`：01 §7.2 + §7.5 + 固定列解析（空格/中文路径真实输出、CRLF/孤立 CR、
        **真实 tree conflict 的列 7 + 续行 + Summary 尾行**、**真实 switched 的列 5**）
  - ✅ `vcs_registry_spec`：01 §7.4 嵌套切换、命令优先于 marker、
        **无 marker 时逐系统探测的回落链（用 stub 模块真正走到 step 循环）**、最后错误透传、
        确定性否定不被 marker 复活、config.systems 顺序
  - ✅ `repo_spec`（20 用例，M6 Step 2 版）：02 §5.1–5.5 + §4 + 二轮回归 —— 「一次元数据事件只广播一次」、
        事件风暴/同窗口多次请求只探测一轮、防抖窗口内手动刷新不双跑、
        `git add`（含 linked worktree）→ 广播、marker 消失 → dispose + `uv_count` 前后相等、
        探测失败不回退 + 单次 warn + 指数退避 + 重试自动恢复（含 `on_error`）、明确否定 → `on_delete`、
        引用计数/共享对象、attach↔detach 竞态不泄漏、dispose 后晚到结果无副作用、
        排队 waiter 不挂起、Windows 大小写折叠、`active()`、
        根目录自身映射回仓库、dispose_all 取消在飞 attach。
        （M6 Step 1 前那批断言缓存的旧用例——`entries()`/`get_status()`/状态矩阵——已随 D38 删除。）
  - ✅ `exec_spec`（13 用例）：**回调必须在主循环**（`in_fast_event()==false` 且回调里可 `nvim_buf_set_lines`）、
        非零退出→`exit N: <首行 stderr>` 且保留 res、命令不存在→`spawn failed` 不抛异常、
        超时→杀死且回调恰好一次、`timeout=0` 表示不超时、config 默认值、`split_nul/split_lines/first_line`、
        **`stdin` 四例**（字符串原样写入不补尾换行 / `string[]` 逐元素补 `\n` / ≥256 KiB 不截断 / 带 stdin 超时不留 timer 句柄）。
  - ✅ `hunk_spec`（20 用例，M6 Step 3）：**纯函数**，不碰仓库——六种类型判定（含首行删除→`topdelete`）、
        `filter_common` 的暂存/未暂存拆分、`sort` 与稳定性、`lines_of` 切片、
        `build_patch` 的**零上下文 unified 输出逐字断言**（省略 `,1`、必须以 `\n` 结尾、`\ No newline at end of file`）、
        以及三个**真实** `git apply --cached --unidiff-zero -` 接受用例（change / 首行插入 / 删除）。
  - ✅ `diff_spec`（10 用例，M6 Step 3）：**纯函数**——`normalize`/`split`/`join` 边界（`''`/`'a'`/`'a\n'`/`'a\n\n'`）、
        空基线全 `add`、两侧相同 0 hunk（**钉住 E5 换行约定**）、一行改动 1 个 `change`、
        `ignore_cr_at_eol` 默认值与覆盖、`algorithm` 透传（myers/histogram 同 hunk）、
        性能防回归（20000 行、孤立改动、hunks == 200、< 200ms——`linematch = true` 对**超大 hunk** 是二次型，见文件注释）。
  - ⬜ `vcs_svn_spec` 的 `<1.9` 降级用例（当前用真实 svn 1.14 只覆盖了 `--show-item` 可用路径）
  - ⬜ git `unstage` 的旧版回退分支（需 git < 2.23，本机无法制造；仅对错误文案做了实测确认）
  - ⬜ `Repo` 的 `refresh_now` 在 fast-event 上下文中被调用时的 `vim.schedule` 分支
  - ✅ `renderer_spec`（15 用例）：排序（严重度→字典序，全 13 个状态的顺序**字面钉住**）/三组与 svn 扁平/
        rename 文本/路径截头留尾**与消息截尾留头**/双 sign 位（priority 与 porcelain 列序）/单域单 sign/
        高亮覆盖 `default=true`/placeholder 三态（含只有失败才染红）/1000 行 7ms。
        **纯函数**：不需要仓库，也不需要二进制，所以它随 `-l test/run.lua renderer_spec` 就能跑。
  - ✅ `sidebar_spec`（13 用例）：窗口/缓冲区选项与 buffer name、屏幕单元格断言 sign 列（`│ A M`）、
        svn 单域、toggle 三语义与缓冲区复用、dispose 连带销毁、光标跟文件走、placeholder→列表、
        失败首刷显示原因、按键**真实按下**（`feedkeys`）、能力门、help、keymap 覆盖/禁用、
        `position = "left"`、`position = "float"` 回落（WARN）、resize 重画、同 root 双系统各一个侧边栏、
        动作抛异常与动作模块加载失败的报告。
        每个用例都包在 `guarded(fn)` 里：**失败也清场**，不留侧边栏/仓库/桩给下一个用例（否则级联失败最难读）。
        实测：headless nvim 仍维护屏幕网格，`screenstring` 能读到 sign 位—所以「两个 sign 列对不对」是**渲染**断言，不是模型断言。
  - ⚠️ **headless 不发 `VimResized` / `WinResized`**（实测：`:vertical resize`、`nvim_win_set_width`、`wincmd >`
        都不触发，`vim.wait` 也等不到，`vim.o.columns = 100` 同样不发）—所以「resize 后重画」的用例分两步断言：注册的事件列表 + `nvim_exec_autocmds('WinResized')` 驱动处理器。
  - ⚠️ 同理，UI 断言靠 `screenstring` 读屏幕网格（headless 仍维护），但**没有 UI 就不发窗口事件**，
        这条差异写进用例注释，避免后来者当成漏测。
  - ✅ `actions_spec`（24 用例）：stage/unstage 后**用 `git diff --cached` 核对**、失败（index.lock）报 VCS 原文、
        commit 走桩输入框（成功/未 stage/取消/空消息四种）并核对 `git log`、svn 现造服务器提交后核对 `svn log`、
        diff（内容/只读/复用缓冲区与窗口/`mode = "split"`/无改动不开窗）、open（deleted 拒开、消失的文件、侧边栏不被顶掉、
        `tab = true`）、refresh（跳过防抖、只有一个仓库时的回落）、仓库外路径明确报错。
        ⚠️ 用例里**不能**用 `^…$` 锚点断言多行 diff：Lua 模式没有多行标志，`^%+changed$` 只匹配整串首尾（会被骗）。
  - ✅ `cli_spec`（17 用例）：空会话里第一条命令就能用、toggle 三语义、未知子命令列全部、**每个子命令都能分派**、
        路径参数（绝对/相对/带空格）、无参时用侧边栏光标行、仓库外 INFO、`debug` 报告内容、补全、嵌套仓库各归各的、
        公共 API（`open`/`close`/`toggle`/`refresh` 无需先 attach、`get_status` 冷调用返回 nil 并把缓存热起来、
        `setup()` 合并选项 + 定义高亮 + 启动 autocmd）、`source plugin/vcssign.vim` 后命令可用。
  - ✅ `autocmds_spec`（10 用例）：事件注册（重复 `setup()` 不叠加）、每缓冲区只 attach 一次、仓库外静默、
        `BufDelete` 释放引用并关监听、`FocusGained` 拉取外部修改、`DirChanged` 换仓库、`on_attach`/`on_detach`
        钩子与抛异常隔离、`VimLeavePre` 后无仓库/侧边栏/`fs_event`/`timer`、`disable()` 幂等。
        ⚠️ `VimLeavePre` 用例要**先等首次 status 落地**再断言句柄数：`exec` 的定时器属于在飞的命令，
        退出清理不负责杀它（04 §7.1）。：stage/unstage/commit 全链路（**必须**在副本仓库上真实跑命令）

---

*来源：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md`，原文 `## 4. lint / format / CI`*（标题层级已下移一级）

### 4. lint / format / CI

- `stylua.toml`：gitsigns 同款（2 空格缩进、单引号、100 列、行尾保留）。实测本仓代码在 100 列下重排 18 个文件 383 行，
  120 列是 10 个文件 156 行——两者都过 `--check`，选 100 是为了与 gitsigns 一致。
- `.luacheckrc`：`std = 'lua51'`、`globals = { 'vim' }`，spec 里用到的 `ok` / `eq` / `check` 前置成只读全局，
  `deps/`、`temp/`、`impl/` 排除（`max_line_length = 120`：给 stylua 的 100 列留出字符串与长调用链的余量）。
- `scripts/tools.sh`：把工具**钉版本**下到 `deps/`（gitignored）——stylua `v2.3.1`（windows-x86_64 / macos-aarch64 /
  macos-x86_64 / linux-x86_64 四个 zip asset）、luacheck `v1.2.0`（只有 Windows 有预编译 exe；其它平台走
  `luarocks install luacheck`，脚本把 PATH 上的它 symlink 进 `deps/`）。已存在就跳过，所以可以挂在每个 make 目标上。
- `Makefile`（44 行；实测 `GNU Make 4.4.1`。Windows 的 git-bash 通常没有 make，`scripts/*.sh` 才是真正的入口）：
  - 默认目标 `help`，另加 `tools` / `fixtures` / `test [FILTER=]` / `format` / `format-check` / `lint`。
  - 依赖只负责「把前置件凑齐」：`test: fixtures tools`、`format*: tools`、`lint: tools`；每个目标仍是一行脚本调用。
  - 文件集来自 `git ls-files 'lua/**/*.lua' 'test/*.lua' 'scripts/*.lua'`（D36）：新加的文件只要 `git add` 过就不会漏检，
    `impl/`、fixture、`deps/` 不在其中。
  - 平台后缀：`EXE := $(if $(filter Windows_NT,$(OS)),.exe,)`，于是 `deps/stylua$(EXE)` 在两边都对。
- `scripts/*.sh` 在索引里置了可执行位（`git update-index --chmod=+x`；本机 `core.filemode=false`，只能这样改），
  POSIX 克隆后可直接 `./scripts/run_tests.sh`；文档与 CI 仍写 `sh scripts/...`。
- CI（`.github/workflows/ci.yml`）：**仍未做**（backlog 不变）——本机没有 GitHub 远端，写了也无法验证。
  接入时的步骤：ubuntu（`apt install subversion` + `luarocks install luacheck`）与 windows 两个 job，
  跑 `make format-check` / `make lint` / `sh scripts/run_tests.sh`；svn 不可用时 `test/run.lua` 打印 SKIP 并继续。

---

*来源：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md`，原文 `## 5. 文档`*（标题层级已下移一级）

### 5. 文档

- `doc/vcssign.txt`（手写初版，254 行，8 节）：安装与设置 / 配置（含全部默认值） / `:Vcssign` 命令表 /
  侧边栏与按键 / 状态与符号（13 种状态 + 严重度顺序） / Lua API / 高亮组（18 组） / 架构（层图 + 测试脚手架）。
  - tag：`*vcssign.txt*`、`*vcssign-contents*` … `*vcssign-arch*`、`*:Vcssign*`；末行 `ft=help` modeline；全文件 LF。
  - `doc/tags` **不入库**（`.gitignore`，D37），由 `:helptags` 或插件管理器生成。
- `test/doc_spec.lua`（7 用例，无外部二进制）：手写文档与代码之间的每一处链接都有断言，不靠纪律防漂移——
  - 文件形状：首行 file tag、末行 modeline、无 CR；
  - tag 唯一且都能被 `:helptags` 索引（在 `temp/_spec/` 的副本上跑，不留生成物）；
  - `config.defaults` 的每个顶层键，加上 `sidebar.position` / `sidebar.width` / `sidebar.group_by` /
    `sidebar.keymaps` / `diff.mode` / `commit.message_input`，以及取值 `left` / `right` / `float` / `vertical` / `input`；
  - `cli.subcommands` 的每个子命令、默认键位的每个动作名、`status_type.default_symbol` /
    `default_sign_hl_group` / `renderer.highlights` 的每个组、公共 API 的每个函数名、`vcssign://` 缓冲名方案。
- 后期（未做）：`scripts/gen_help.lua` 从 `config.lua` 的 schema 生成配置段（gitsigns `make doc` 模式）。

---

*来源：`loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md`，原文 `## 7. M5 实测与踩坑`*（标题层级已下移一级）

### 7. M5 实测与踩坑

- stylua 100 列 vs 120 列：100 列重排 18 文件 383 行，120 列 10 文件 156 行；两者都过 `--check`，选 100 只为与 gitsigns 一致。
- luacheck 真找出的问题（都不是风格问题，全是「改了不报错但没用」或遮蔽）：
  `test/sidebar_spec.lua` 一个未使用的 `win`、`test/cli_spec.lua` 一个未使用的局部函数、
  `test/autocmds_spec.lua` 里遮蔽外层 `elsewhere` 的局部、`lua/vcssign/actions.lua` 里遮蔽 `err` 的变量。
  修法都是删除或改名，不改行为——修完全量 174/174 仍绿。
- `max_line_length` 用 120 而不是 100：字符串与长调用链本来就常越过 100 列，硬卡只会逼出无意义的换行。
- headless 的 `:helptags` 会真的写 `tags` 文件：`doc_spec` 把它写到 `temp/_spec/` 的副本上（仓库里同时 `.gitignore` 了 `doc/tags`）。
- 手写长文件在本机工具链下会被截断（一次 heredoc 超过约 7KB 时）：`doc/vcssign.txt` 实际踩到过（在 245 行处断句），
  最后是「先写、再按行号补齐」落地的；写文档时按小节分开写更稳。
