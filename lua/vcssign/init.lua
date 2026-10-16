--- The public API: `require('vcssign')`.
---
--- Three kinds of entry point live here, and nothing else:
---   * `setup` — configuration and lifecycle autocmds.  Optional; the plugin
---     works without it (defaults), it just does not attach by itself.
---   * `refresh` — takes a path, a buffer, or nothing at all, and attaches the
---     repository when nothing has yet, so a mapping works as the first thing a
---     user presses.
---   * `M.cli` — the `:Vcssign` implementation the plugin file loads.
--- The sign and hunk API is layered on top of this in later milestones.
--- See impl/init/04-commands-actions.md §5.
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')
local manager = require('vcssign.repo_manager')

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

--- Where a verb with no path applies: the current buffer's file, the cwd when
--- the buffer has no name.
---@return string
local function current_path()
  local name = vim.api.nvim_buf_get_name(0)
  return name ~= '' and name or (vim.uv.cwd() or '.')
end

--- Run `fn` for the repository containing `path`, attaching it if needed.
---@param path string?
---@param fn fun(repo: vcssign.Repo)
local function with_repo(path, fn)
  local target = path or current_path()
  manager.ensure(target, function(err, repo)
    if not repo then
      -- Same wording and level as `:Vcssign` (one implementation): a missing
      -- repository is an answer, an environmental failure is an error.
      return M.cli.report_no_repo(target, err)
    end
    fn(repo)
  end)
end

--- Refresh the repository containing `path` now (skipping the debounce).
---@param path string?
function M.refresh(path)
  with_repo(path, function(repo)
    repo:refresh_now()
  end)
end

return M
