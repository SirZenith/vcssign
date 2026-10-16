--- The default buffer-local keymaps (§4) and the action dispatch behind them.
---
--- `config.keymaps` is `lhs -> action name`, and `false` turns every default
--- mapping off.  The mappings are installed by `attach` — only for a buffer
--- that actually got its signs — and removed by `detach`.
---
--- `dispatch` is the single entry point a mapping calls, so the mapping does
--- not need to know which module implements an action, and an action that does
--- not exist yet answers the person who pressed the key instead of failing
--- silently.  Step 8 landed navigation, Step 9 the hunk actions, Step 10 the
--- hunk preview and the word-diff switch, Step 11 blame and the rev diff; the
--- quickfix lists of the backlog are the only keys still absent from `ACTIONS`.
local api = vim.api
local config = require('vcssign.config')

local M = {}

--- `vcssign.nav`, resolved when a key is pressed rather than at load time.
---
--- `attach` requires this module, this module would require `nav`, and `nav`
--- requires `attach`: a plain top-level require here is the cycle Neovim reports
--- as "loop or previous error loading module 'vcssign.attach'".  A press costs
--- one `package.loaded` lookup, which is nothing next to the jump itself.
---@return table
local function navigator()
  return require('vcssign.nav')
end

--- `vcssign.actions`, resolved the same way — it requires `attach` too.
---@return table
local function acts()
  return require('vcssign.actions')
end

--- Everything a mapping hands to an action.
---@class vcssign.KeymapCtx
---@field bufnr integer    the buffer the mapping belongs to
---@field count integer    `vim.v.count1`: the count typed before the key
---@field wrap? boolean    navigation only; `false` stops at the ends

--- action name -> implementation.
---
--- This is deliberately *not* all of `config.keymaps`: the keys whose
--- implementation has not been written yet are missing on purpose, and
--- `dispatch` says so.  When a later step lands, its entry is added here and
--- nothing else in this file changes.
---@type table<string, fun(ctx: vcssign.KeymapCtx)>
local ACTIONS = {
  next_hunk = function(ctx)
    return navigator().next(ctx.bufnr, ctx.count, ctx)
  end,
  prev_hunk = function(ctx)
    return navigator().prev(ctx.bufnr, ctx.count, ctx)
  end,
  -- Hunk actions (§4).  `nil` target: the action works on the buffer the mapping
  -- belongs to, which `ctx.bufnr` carries — the mapping is buffer-local, so the
  -- buffer that was current when the key was pressed is the one it edits.
  stage_hunk = function(ctx)
    return acts().stage_hunk(nil, ctx)
  end,
  undo_stage_hunk = function(ctx)
    return acts().undo_stage_hunk(nil, ctx)
  end,
  reset_hunk = function(ctx)
    return acts().reset_hunk(nil, ctx)
  end,
  stage_buffer = function(ctx)
    return acts().stage_buffer(nil, ctx)
  end,
  reset_buffer = function(ctx)
    return acts().reset_buffer(nil, ctx)
  end,
  -- Previews (§4): `hp` opens and closes the hunk preview, `tw` is the
  -- session-wide word-diff switch.
  preview_hunk = function(ctx)
    return acts().preview_hunk(nil, ctx)
  end,
  toggle_word_diff = function()
    return acts().toggle_word_diff()
  end,
  -- Blame and the rev diff (§4): `hb` blames a line, `hd`/`hD` compare the file
  -- with the configured revision or with one the user types, and `tb` is the
  -- session-wide current-line-blame switch.
  blame_line = function(ctx)
    return acts().blame_line(nil, ctx)
  end,
  diffthis = function(ctx)
    return acts().diffthis(nil, ctx)
  end,
  diffthis_rev = function(ctx)
    return acts().diffthis_rev(nil, ctx)
  end,
  toggle_current_line_blame = function()
    return acts().toggle_current_line_blame()
  end,
}

--- Run one action for one buffer.
---@param action string
---@param opts? { bufnr?: integer, count?: integer, wrap?: boolean }
---@return any  what the action returns (navigation: the line jumped to)
function M.dispatch(action, opts)
  ---@type vcssign.KeymapCtx
  local ctx = {
    bufnr = (opts and opts.bufnr) or api.nvim_get_current_buf(),
    count = (opts and opts.count) or vim.v.count1,
    wrap = opts and opts.wrap,
  }
  local fn = ACTIONS[action]
  if fn then
    return fn(ctx)
  end
  -- Once per action per session: pressing an unimplemented key twice must not
  -- stack two notices on top of each other.
  vim.notify_once(string.format('vcssign: %s is not implemented yet', action), vim.log.levels.WARN)
  return nil
end

--- Install the default buffer-local mappings for `bufnr`.
---@param bufnr integer
function M.attach(bufnr)
  local maps = config.get().keymaps
  if maps == false then
    return
  end
  for lhs, action in pairs(maps) do
    if type(action) == 'string' then
      vim.keymap.set('n', lhs, function()
        M.dispatch(action, { bufnr = bufnr })
      end, { buffer = bufnr, silent = true, desc = 'vcssign ' .. action })
    end
  end
end

--- Remove the mappings this module installed for `bufnr`.
---
--- Only the configured `lhs` are touched and a mapping that is not there is not
--- an error — autocmds drive `attach`/`detach`, and a `:e!` cycle runs both.
--- vim keeps one mapping per lhs, so a user mapping on the same lhs was
--- overwritten while the buffer was attached; deleting it here is the honest
--- counterpart of having installed it.
---@param bufnr integer
function M.detach(bufnr)
  local maps = config.get().keymaps
  if maps == false then
    return
  end
  for lhs in pairs(maps) do
    pcall(vim.keymap.del, 'n', lhs, { buffer = bufnr })
  end
end

return M
