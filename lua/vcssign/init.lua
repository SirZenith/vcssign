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
local registry = require('vcssign.vcs')
local sidebar = require('vcssign.sidebar')
local base = require('vcssign.vcs.base')

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
      -- Same wording and level as `:Vcssign` (one implementation): a missing
      -- repository is an answer, an environmental failure is an error.
      return M.cli.report_no_repo(target, err)
    end
    fn(repo)
  end)
end

--- The repository that owns `path`, preferring the nearest marker.
---
--- Same rule as the command layer's `ensure` (D29), so a nested repository is
--- not answered with its parent's cache — and a path that belongs to a
--- repository nobody tracks yet resolves to nil, which is what makes the
--- warm-up below possible.
---@param abs string
---@return vcssign.Repo?
local function repo_for(abs)
  local detection = registry.detect(abs)
  if detection then
    return manager.get(detection.root)
  end
  return manager.get_by_path(abs)
end

--- Paths whose warm-up is still in flight: a caller polling a cold path in a
--- loop should not spawn one detection per call.
---@type table<string, true>
local warming = {}

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

--- Warm the cache for `abs` up in the background, once at a time.
---@param abs string
local function warm_up(abs)
  if warming[abs] then
    return
  end
  warming[abs] = true
  -- One shared reference, deliberately: a read-only peek should not pin a
  -- repository (and its watcher) per path — that is what `ensure` is for.  The
  -- side effect is that warming a second repository releases the first one if
  -- nothing else holds it; integrations can `detach('get_status')` themselves.
  manager.attach('get_status', abs, function(err)
    warming[abs] = nil
    log.debug('get_status(%s): %s', abs, err or 'attached')
  end)
end

--- The cached status of one file, or nil when there is nothing to report yet.
---
--- Never blocks: a path whose repository is not tracked yet is looked up in the
--- background, so a later call can answer.
---@param path string?  defaults to the current buffer's file
---@return vcssign.FileStatus?
function M.get_status(path)
  local abs = base.normalize(path or current_path())
  local repo = repo_for(abs)
  if not repo then
    warm_up(abs)
    return nil
  end
  return repo:get_status(abs)
end

--- Every status entry of the repository containing `path` (as the sidebar shows
--- them), or an empty list.  Same non-blocking rule as `get_status`.
---@param path string?
---@return vcssign.StatusEntry[]
function M.get_entries(path)
  local abs = base.normalize(path or current_path())
  local repo = repo_for(abs)
  if not repo then
    warm_up(abs)
    return {}
  end
  return repo:entries()
end

return M
