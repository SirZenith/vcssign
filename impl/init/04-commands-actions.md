# 04 · 用户命令、动作、autocmd 生命周期（P3）

> UI 就绪后的最后一层能力：把 01–03 的模块串成「一键可用」的入口
> （`:Vcssign` 命令族、自动 attach、动作分发）。

## 1. 交付物

| 文件 | 职责 |
|------|------|
| `lua/vcssign/cli.lua` | `:Vcssign` 子命令分发 + 命令补全 |
| `lua/vcssign/actions.lua` | 动作层：open / diff / stage / unstage / commit / refresh（按 capabilities 分派） |
| `lua/vcssign/autocmds.lua` | 生命周期 autocmd（attach 触发、清理） |
| `plugin/vcssign.vim` | 命令注册（`nvim_create_user_command`），setup 延迟加载入口 |

## 2. 动作层（actions.lua）—— 按 VCS 能力分派

能力声明（01 的 base 接口）：

```lua
---@class vcssign.VcsCaps
---@field stage boolean       # git: true, svn: false
---@field unstage boolean     # git: true, svn: false
---@field commit boolean      # 两者 true
---@field diff boolean        # 两者 true
```

所有动作签名统一（单 repo 上下文；无参时默认作用于 `renderer.item_at` 当前条目）：

```lua
actions.open(entry)          # :e / tabopen 文件（deleted/missing 状态跳转时提示）
actions.diff(entry)          # diff 展示（见 §2.1）
actions.stage(entry)         # capability gate → system.stage(root, {entry.rel_path})
actions.unstage(entry)       # git only
actions.commit(...)          # 见 §2.2
actions.refresh()            # Repo:refresh
```

完成后的统一收尾：动作成功 → 触发 `Repo:refresh()`（强制拉新，staging 会翻转状态）；失败 → `vim.notify(err, ERROR)`。**所有动作走 02 的 exec 封装**，UI 层（03 keymap）只调 actions，层次干净。

### 2.1 diff 展示

两种实现（config：`diff.mode = "vertical" | "split"`）：

- git：`git --no-pager diff --no-color HEAD -- <file>` 取 unified diff → 借鉴 vcs-helper `systems/base.lua` 的 `parse_diff_hunk`（unified diff 解析已成参考）**但不引入它的渲染**——更简单的方案：diff 输出直接灌进一个 `vcssign-diff` nofile 缓冲区，`filetype=diff` 让内置 syntax 上色，这是初版方案。
- 与暂存内容对比：`git diff --cached -- <file>`（分组在 Staged 时用这个）。
- svn：`svn diff -- <file>` 同上灌缓冲区。
- 后续增强（列 backlog，不进初版）：左右窗 worktree vs HEAD 对比（gitsigns `actions/diffthis.lua` 是参考）。

### 2.2 commit

- `vim.ui.input` 取单行 message（config `commit.message_input = "input" | "buffer"`，初版只 `"input"`；`"buffer"`= 临时缓冲区提交，gitsigns `actions/commit.lua` 是参考，backlog）。
- git：选中文件先确保 staged（在 Staged 组的条目直接 `git commit -m msg -- <files>`；跨组混合提交初版**禁止**——提示先 stage）。
- svn：`svn commit -m msg -- <files>`。
- 提交后强制 refresh；失败原样 notify（svn 服务端连接错误的 stderr 有价值，整段展示）。

## 3. `:Vcssign` 命令族（cli.lua + plugin/vcssign.vim）

仿 gitsigns `:Gitsigns`（`cli.lua` 的子命令分发 + 补全），但去掉它的 argparse 通用化（初版不需要 `key=value` 参数解析，只做 `- nargs="*" -complete=customlist`）：

| 子命令 | 效果 |
|--------|------|
| `:Vcssign toggle`（默认，无参） | 侧边栏 toggle（03 §2 语义） |
| `:Vcssign open [path]` | 打开 path（默认当前文件/cwd）所属 repo 侧边栏 |
| `:Vcssign close` | 关闭 |
| `:Vcssign refresh` | 强制刷新当前 repo |
| `:Vcssign stage [path]` / `unstage [path]` | 动作层入口（git only） |
| `:Vcssign commit` | §2.2 |
| `:Vcssign debug` | 打印当前 repo 状态缓存 + 监听句柄数（排障用，gitsigns `:Gitsigns debug_messages` 的定位） |

补全：`customlist` 枚举子命令（gitsigns `cli.complete` 的简化版）；`stage/unstage` 补全当前条目 rel_path 可后置，初版只补子命令。

`plugin/vcssign.vim` 只做 `nvim_create_user_command("Vcssign", ...)`，实现体 `require("vcssign").cli.run(params)`——保持 gitsigns 的「plugin/ 最薄」惯例。

## 4. autocmds.lua —— 生命周期

一个 augroup `vcssign`（gitsigns attach.lua 的 group 模式）：

| 事件 | 处理 |
|------|------|
| `BufReadPost` / `BufEnter`（filetype 非 vcssign 的普通文件） | `repo_manager.attach(expand("<afile>:p"))`（02 会话内幂等） |
| `DirChanged`（global/cwd） | 重新探测 cwd 的 repo；attach（当前文件 repo 不变则无事） |
| `FocusGained` | `Repo:refresh()`（兜底：外部编辑器/终端改文件，Windows 上的可靠兜底） |
| `VimLeavePre` | 全 repo `dispose()`（02 §4 清理路径） |
| `OptionSet signcolumn`（可选） | 不处理（窗口内强制 `signcolumn=yes:2`，见 03 §2） |

`setup()` 时创建 group；`config.on_attach` / `on_detach` 回调钩子（gitsigns config 同款命名），给用户集成点。

去抖：attach 调用全部经 `debounce_trailing(100ms)` 包装（repo_manager 内部），防 BufEnter 风暴连跑探测命令。

## 5. 公共 API（lua/vcssign/init.lua）

```lua
require("vcssign").setup(opts)         # config schema 校验 + 默认高亮 + autocmd 建组
require("vcssign").refresh([path])
require("vcssign").open([path]) / close() / toggle()
require("vcssign").get_status(path)    # 单文件状态（第三方集成入口，对标 gitsigns 的 b:gitsigns_status_dict 角色）
```

`get_status` 保证「不在仓库返回 nil，仓库存在但未刷新不阻塞」（直接返回缓存，nil 时后台触发 attach+refresh）——供 oil-vcs-status 这类集成未来消费（backlog，见 00 非目标）。

## 6. 验收标准

1. 空目录 / 非 VCS 目录：`:Vcssign toggle` → `notify "no repository found"`（INFO 级，不报错）。
2. git 仓库全链路：toggle 打开 → `s` stage → 状态翻转到 Staged 组（依赖 `.git` 监听或动作后强制 refresh）→ `u` unstage 回 → `:Vcssign commit` 提交后列表清空。
3. svn 仓库：无 stage/unstage 键生效（提示）→ `:Vcssign commit` 提交成功 → 列表清空。
4. 外部修改（终端 `echo >> file`）→ FocusGained / fs 监听两条路都能把变化带进侧边栏。
5. `VimLeavePre` 后无残留 uv handle（headless spec 断言 `loop Walking` 状态）。
6. 命令补全在输入 `:Vcssign ` 后列出全部子命令。
