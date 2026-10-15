--- The public API: `require('vcssign')`.
---
--- Three kinds of entry point live here, and nothing else:
---   * `setup` — configuration, highlights, lifecycle autocmds.  Optional; the
---     plugin works without it (defaults), it just does not attach by itself.
---   * the sidebar verbs (`toggle`/`open`/`close`/`refresh`) — each tolerates a
---     path, a buffer, or nothing at all, and attaches the repository when
---     nothing has yet, so a mapping works as the first thing a user presses.
---   * `get_status` — a read-only peek at the cache for integrations.
--- See impl/init/04-commands-actions.md §5.
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local sidebar = require('vcssign.sidebar')
local base = require('vcssign.vcs.base')

local M = {}

--- `:Vcssign`'s implementation, kept reachable from the module the plugin file
--- loads first (`require('vcssign').cli.run(...)`).
M.cli = require('vcssign.cli')

--- Configure the plugin and start the lifecycle autocmds.
---@param opts? vcssign.Config
---@return table M
function M.setup(opts)
  config.setup(opts)
  renderer.define_highlights()
  autocmds.setup()
  return M
end

--- Where a verb with no path applies: the current buffer's file, the cwd when
--- the buffer has no name.
---@return string
local function current_path()
  local state = sidebar.state_of_buf(vim.api.nvim_get_current_buf())
  if state then
    return state.repo.root
  end
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
      if not (err and err:find('attach cancelled', 1, true)) then
        log.notify('no repository found for ' .. target)
      end
      return
    end
    fn(repo)
  end)
end

--- Open the sidebar for the repository containing `path`.
---@param path string?  defaults to the current buffer's file, then the cwd
function M.open(path)
  with_repo(path, function(repo)
    sidebar.open(repo)
  end)
end

--- Close the sidebar for the repository containing `path`.
---@param path string?
function M.close(path)
  with_repo(path, function(repo)
    sidebar.close(repo)
  end)
end

--- `close` when it is focused, focus when it is open, `open` when it is closed.
---@param path string?
function M.toggle(path)
  with_repo(path, function(repo)
    sidebar.toggle(repo)
  end)
end

--- Refresh the repository containing `path` now (skipping the debounce).
---@param path string?
function M.refresh(path)
  with_repo(path, function(repo)
    repo:refresh_now()
  end)
end

--- The cached status of one file, or nil when there is nothing to report yet.
---
--- Never blocks: an unattached path is looked up in the background so a later
--- call can answer.  The reference is kept under a stable name (`get_status`)
--- so repeated calls do not accumulate repositories; integrations that want to
--- stop pinning one can `require('vcssign.repo_manager').detach('get_status')`.
---@param path string?  defaults to the current buffer's file
---@return vcssign.FileStatus?
function M.get_status(path)
  local target = base.normalize(path or current_path())
  local repo = manager.get_by_path(target)
  if not repo then
    manager.attach('get_status', target, function(err)
      log.debug('get_status(%s): %s', target, err or 'attached')
    end)
    return nil
  end
  return repo:get_status(target)
end

--- Every status entry of the repository containing `path` (as the sidebar
--- shows them), or an empty list.  Same non-blocking rule as `get_status`.
---@param path string?
---@return vcssign.StatusEntry[]
function M.get_entries(path)
  local repo = manager.get_by_path(base.normalize(path or current_path()))
  return repo and repo:entries() or {}
end

return M
