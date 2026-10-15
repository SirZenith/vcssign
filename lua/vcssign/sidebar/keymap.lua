--- Sidebar-local keymaps.
---
--- The split is deliberate: the keys that are pure UI (`q`, `r`, `?`) are
--- handled here, and everything that ends up running a VCS command is delegated
--- to `vcssign.actions` (04), resolved lazily so this file works before that
--- module exists.  The UI layer therefore never builds a command line itself
--- (03 §5) — it only asks for the entry under the cursor.
---
--- Capability gating happens *before* the delegation: svn has no staging area,
--- and a user pressing `s` deserves a sentence rather than a silent nothing.
local config = require('vcssign.config')
local log = require('vcssign.log')
local renderer = require('vcssign.sidebar.renderer')

local M = {}

--- Actions that need a declared VCS capability.
---@type table<string, string>  action -> field of vcssign.VcsCaps
local NEEDS_CAP = { stage = 'stage', unstage = 'unstage', diff = 'diff' }

---@param msg string
---@param level? integer
local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO)
end

--- `vcssign.actions` once it exists (M4), nil before that.
---@return table<string, function>?
local function actions()
  local ok, mod = pcall(require, 'vcssign.actions')
  return ok and mod or nil
end

--- Capability gate message, phrased per action.
---@param action string
---@param repo vcssign.Repo
---@return string
local function unsupported(action, repo)
  if action == 'stage' or action == 'unstage' then
    return string.format('%s: no staging area', repo.system.name)
  end
  return string.format('%s: %s is not supported', repo.system.name, action)
end

--- Which file the action applies to: the entry under the cursor of the window
--- showing the sidebar (the current window for a real key press).
---@param ctx { repo: vcssign.Repo, bufnr: integer }
---@return vcssign.StatusEntry?
local function cursor_entry(ctx)
  local win = vim.fn.bufwinid(ctx.bufnr)
  if win == -1 then
    win = vim.api.nvim_get_current_win()
  end
  return renderer.entry_at(ctx.bufnr, vim.api.nvim_win_get_cursor(win)[1] - 1)
end

--- Run one sidebar action.
---
--- Split out from the mappings so it can be called (and asserted on) without
--- going through `nvim_feedkeys`, and so `:Vcssign`'s key-driven paths and the
--- editor's real key presses take the same route.
---@param action string        action name, as used in `sidebar.keymaps`
---@param ctx { repo: vcssign.Repo, bufnr: integer }
function M.dispatch(action, ctx)
  local repo = ctx.repo

  if action == 'refresh' then
    -- Skips the debounce: the user asked, so an answer now is the point.
    repo:refresh_now()
    return
  end
  if action == 'close' then
    local win = vim.fn.bufwinid(ctx.bufnr)
    if win ~= -1 then
      vim.api.nvim_win_close(win, true)
    end
    return
  end
  if action == 'help' then
    M.show_help()
    return
  end

  local cap = NEEDS_CAP[action]
  if cap and not repo.system.capabilities[cap] then
    notify(unsupported(action, repo))
    return
  end

  local entry = cursor_entry(ctx)
  if not entry then
    notify('vcssign: no file on this line', vim.log.levels.INFO)
    return
  end

  local mod = actions()
  if mod == nil then
    -- M3 ships the sidebar without the action layer; say so instead of
    -- pretending the key is unbound.
    notify(string.format("vcssign: the '%s' action is not implemented yet", action))
    return
  end
  -- `open_tab` is `open` with a hint, so an action never has two entry points.
  local name = action == 'open_tab' and 'open' or action
  local fn = mod[name]
  if type(fn) ~= 'function' then
    log.warn('no handler for action %s', action)
    notify(string.format("vcssign: the '%s' action is not implemented yet", action))
    return
  end
  local ok, err = pcall(fn, entry, action == 'open_tab' and { tab = true } or nil)
  if not ok then
    log.error('action %s failed: %s', action, tostring(err))
    notify('vcssign: ' .. tostring(err), vim.log.levels.ERROR)
  end
end

--- Echo the active mappings (the `?` key).  Reads the *effective* config, so
--- user overrides show up as they are.
function M.show_help()
  local lines = {}
  for lhs, action in pairs(config.get().sidebar.keymaps) do
    if action then
      lines[#lines + 1] = string.format('%-6s %s', lhs, action)
    end
  end
  table.sort(lines)
  notify('vcssign sidebar\n' .. table.concat(lines, '\n'))
end

--- Bind the configured keys in a sidebar buffer.
---@param bufnr integer
---@param ctx { repo: vcssign.Repo }
function M.attach(bufnr, ctx)
  for lhs, action in pairs(config.get().sidebar.keymaps) do
    if action then
      vim.keymap.set('n', lhs, function()
        M.dispatch(action, { repo = ctx.repo, bufnr = bufnr })
      end, {
        buffer = bufnr,
        desc = 'vcssign: ' .. action,
        silent = true,
        nowait = true,
      })
    end
  end
end

return M
