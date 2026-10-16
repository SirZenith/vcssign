--- The public API: `require('vcssign')`.
---
--- Three kinds of entry point live here, and nothing else:
---   * `setup` — configuration and lifecycle autocmds.  Optional; the plugin
---     works without it (defaults), it just does not attach by itself.
---   * the buffer API — `attach` / `detach` / `toggle` / `get_hunks` on top of
---     `attach.lua`, so a mapping can drive the signs without the command.
---   * `refresh` — takes a path, or nothing at all, and attaches the
---     repository when nothing has yet, so a mapping works as the first thing a
---     user presses.  It is the `:Vcssign refresh` implementation, not a second
---     copy of it.
--- `M.cli` — the `:Vcssign` implementation the plugin file loads — is exposed
--- alongside them for the same reason.
--- See impl/init/07-signs-in-signcolumn.md §6 and impl/init/04-commands-actions.md §5.
local api = vim.api
local attach = require('vcssign.attach')
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')

local M = {}

--- `:Vcssign`'s implementation, kept reachable from the module the plugin file
--- loads first (`require('vcssign').cli.run(...)`).
M.cli = require('vcssign.cli')

--- Configure the plugin and start the lifecycle autocmds.
---
--- Options are merged over the *defaults* (not over a previous call), so
--- calling `setup()` twice with different tables does not accumulate: the last
--- call wins for every key it mentions.
---@param opts? vcssign.Config
---@return table M
function M.setup(opts)
  config.setup(opts)
  autocmds.setup()
  return M
end

--- Attach a buffer to the signs pipeline (default: the current buffer).
---
--- Returns the state table, or `nil` when the buffer has no file to diff
--- (unnamed, a `nofile` buffer, missing on disk, over `max_file_length`).
---@param bufnr? integer
---@return vcssign.AttachState?
function M.attach(bufnr)
  return attach.attach(bufnr)
end

--- Stop drawing signs in a buffer and release its repository reference.
---@param bufnr? integer
function M.detach(bufnr)
  attach.detach(bufnr or api.nvim_get_current_buf())
end

--- Turn a buffer's signs on or off (`:Vcssign toggle`).
---@param bufnr? integer
---@return boolean? shown  the new state, `nil` when the buffer cannot be attached
function M.toggle(bufnr)
  return attach.toggle(bufnr or api.nvim_get_current_buf())
end

--- The hunks currently drawn for a buffer (empty when it has none).
---@param bufnr? integer
---@return vcssign.Hunk[]
function M.get_hunks(bufnr)
  return attach.hunks(bufnr or api.nvim_get_current_buf())
end

--- Refresh the signs of the file at `path` and the repository containing it,
--- now instead of after the debounce.
---
--- Delegates to `:Vcssign refresh` so the API and the command can never drift
--- apart; with no argument it acts on the current buffer's file.
---@param path string?
function M.refresh(path)
  return M.cli.run(path and { 'refresh', path } or { 'refresh' })
end

return M
