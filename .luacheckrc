-- luacheck 配置（M5，05 §4）。
--
-- 仓库是 Neovim 插件：除宿主注入的全局外，一切都来自 `require`。
std = 'luajit'

-- `vim` 是宿主全局，而且**要可写**：`vim.bo[..]` / `vim.wo[..]` 靠元表写入，
-- 测试还会替换 `vim.notify` / `vim.ui.input` / `vim.system`。用 `read_globals`
-- 会把这些都报成 W122，所以这里是 `globals`。
-- 三个断言助手由 test/run.lua 挂到 `_G` 上（`_G.ok = helpers.ok`），对 spec 也是全局。
globals = { 'vim', 'ok', 'eq', 'check' }

-- 计划文档（非 Lua）与下载下来的工具不参与 lint。
exclude_files = { 'loop/**', 'deps/**', 'temp/**' }

-- 行长：代码本身由 stylua 管到 100 列（stylua.toml），这里放宽到 120 只是为了
-- 那些**格式化器换不了行**的东西——`---@field` 类型注解与用户可见的长消息字符串。
max_line_length = 120
unused_args = false -- 回调式 API 常按签名占位（如 `function(_err)`）
