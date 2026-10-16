--- M6 Step 5–7: the sign layer's placement rules and highlight groups.
--- See impl/init/07-signs-in-signcolumn.md §3.2 / §4 (D40).
---
--- No repository and no VCS binary: `signs.lua` maps `vcssign.Hunk[]` onto
--- extmarks, so a scratch buffer pins every rule (which line a hunk anchors on,
--- which type becomes `changedelete`, which group the number / whole line get).
local api = vim.api

local config = require('vcssign.config')
local signs = require('vcssign.signs')

--- The attributes a group resolves to, following links.
---@param name string
---@return table
local function resolved(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end

--- Run a case, then reset the config it may have changed, even when it failed.
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- A scratch buffer with `lines`, deleted when `fn` returns.
---@param lines string[]
---@param fn fun(bufnr: integer)
local function with_buf(lines, fn)
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  local ok, err = pcall(fn, bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_delete(bufnr, { force = true })
  end
  if not ok then
    error(err, 0)
  end
end

--- Extmarks of one layer, with their details, as `{ id, row, col, details }`.
---@param bufnr integer
---@param staged? boolean
local function extmarks(bufnr, staged)
  return api.nvim_buf_get_extmarks(bufnr, signs.namespace(staged), 0, -1, { details = true })
end

--- row (0-based) -> details of the sign on it.
---@param bufnr integer
---@param staged? boolean
local function rows(bufnr, staged)
  local out = {}
  for _, mark in ipairs(extmarks(bufnr, staged)) do
    out[mark[2]] = mark[4]
  end
  return out
end

--- Extmark `sign_text` is padded to the sign column width; compare trimmed.
---@param details table
---@return string
local function signtext(details)
  return vim.trim(details.sign_text or '')
end

---@param ty string
---@param start integer
---@param count integer
---@param removed_start? integer
---@param removed_count? integer
local function hunk(ty, start, count, removed_start, removed_count)
  return {
    type = ty,
    added = { start = start, count = count },
    removed = { start = removed_start or 0, count = removed_count or 0 },
  }
end

return {
  {
    name = 'define_highlights links the six types to their Diff groups, twice',
    fn = guarded(function()
      signs.define_highlights()
      signs.define_highlights()

      local function link(name)
        return api.nvim_get_hl(0, { name = name, link = true }).link
      end

      eq(link('VcssignAdd'), 'DiffAdd')
      eq(link('VcssignChange'), 'DiffChange')
      eq(link('VcssignDelete'), 'DiffDelete')
      eq(link('VcssignTopDelete'), 'DiffDelete')
      eq(link('VcssignChangeDelete'), 'VcssignChange')
      eq(link('VcssignUntracked'), 'VcssignAdd')

      -- The staged layer is the suffix form, not gitsigns' prefix form, and —
      -- since Step 7 — the worktree colour faded toward the background rather
      -- than a second name for the same colour.
      eq(link('VcssignAddNr'), 'VcssignAdd')
      eq(link('VcssignAddLn'), 'DiffAdd')
      eq(link('VcssignAddCul'), 'VcssignAdd')
      eq(link('VcssignAddStagedNr'), 'VcssignAddStaged')
      ok(link('VcssignAddStaged') == nil, 'the staged group is a colour of its own')
      local staged = resolved('VcssignAddStaged')
      ok(staged.fg ~= nil, 'and it has a foreground')
      ok(staged.fg ~= resolved('VcssignAdd').fg, 'that is dimmer than the worktree one')
      -- `delete` anchors on a line that is *not* removed: no whole-line group.
      eq(link('VcssignDeleteLn'), nil)
      eq(link('VcssignTopDeleteLn'), nil)
    end),
  },
  {
    name = 'the staged layer falls back to a link when the colours cannot be blended',
    fn = guarded(function()
      -- A `cterm`-only theme leaves `Normal` without a background, and a
      -- guessed "dimmer" would be worse than the worktree colour.  The groups
      -- are cleared with `:highlight clear` first: they were defined with
      -- `default = true`, and a group that `nvim_set_hl` has merely been reset
      -- to `{}` still counts as defined, so `default = true` would not fill it
      -- (measured on 0.12.4).
      local types = { 'add', 'change', 'delete', 'topdelete', 'changedelete', 'untracked' }
      local function clear_staged()
        for _, ty in ipairs(types) do
          vim.cmd('highlight clear ' .. signs.hl_name(ty, true))
        end
      end
      local saved_normal = api.nvim_get_hl(0, { name = 'Normal' })
      local passed, err = pcall(function()
        api.nvim_set_hl(0, 'Normal', {})
        clear_staged()
        signs.define_highlights()
        eq(api.nvim_get_hl(0, { name = 'VcssignAddStaged', link = true }).link, 'VcssignAdd')
      end)
      -- Put the theme and the fade back for the specs that run after this one.
      api.nvim_set_hl(0, 'Normal', saved_normal)
      clear_staged()
      signs.define_highlights()
      if not passed then
        error(err, 0)
      end
      ok(resolved('VcssignAddStaged').fg ~= nil, 'the fade is back afterwards')
    end),
  },
  {
    name = 'add places one sign per added line',
    fn = guarded(function()
      with_buf({ 'a', 'b', 'c', 'd' }, function(bufnr)
        local placed = signs.place(bufnr, { hunk('add', 1, 3) })
        eq(placed, 3)
        local r = rows(bufnr)
        for i = 0, 2 do
          eq(signtext(r[i]), '▎')
          eq(r[i].sign_hl_group, 'VcssignAdd')
          eq(r[i].priority, 6)
        end
      end)
    end),
  },
  {
    name = 'change marks the last line changedelete when more lines went away',
    fn = guarded(function()
      with_buf({ '1', '2', '3', '4' }, function(bufnr)
        signs.place(bufnr, { hunk('change', 2, 2, 2, 4) })
        local r = rows(bufnr)
        eq(r[1].sign_hl_group, 'VcssignChange')
        eq(signtext(r[1]), '▎')
        eq(r[2].sign_hl_group, 'VcssignChangeDelete')
        eq(signtext(r[2]), '~')
      end)
    end),
  },
  {
    name = 'change keeps every line change when the counts match',
    fn = guarded(function()
      with_buf({ '1', '2', '3', '4' }, function(bufnr)
        signs.place(bufnr, { hunk('change', 2, 2, 2, 2) })
        local r = rows(bufnr)
        eq(r[1].sign_hl_group, 'VcssignChange')
        eq(r[2].sign_hl_group, 'VcssignChange')
      end)
    end),
  },
  {
    name = 'delete anchors on the line above the removed block',
    fn = guarded(function()
      config.setup({ signs = { linehl = true } })
      with_buf({ 'a', 'b', 'c', 'd', 'e' }, function(bufnr)
        signs.place(bufnr, { hunk('delete', 0, 0, 4, 2) })
        local r = rows(bufnr)
        eq(signtext(r[2]), '▁')
        eq(r[2].sign_hl_group, 'VcssignDelete')
        -- The line is *not* removed, so no whole-line diff highlight.
        eq(r[2].line_hl_group, nil)
      end)
    end),
  },
  {
    name = 'topdelete anchors on the first line',
    fn = guarded(function()
      with_buf({ 'a', 'b', 'c' }, function(bufnr)
        signs.place(bufnr, { hunk('topdelete', 0, 0, 1, 2) })
        local r = rows(bufnr)
        eq(signtext(r[0]), '‾')
        eq(r[0].sign_hl_group, 'VcssignTopDelete')
      end)
    end),
  },
  {
    name = 'untracked covers every line of the buffer',
    fn = guarded(function()
      with_buf({ 'x', 'y', 'z' }, function(bufnr)
        local placed = signs.place(bufnr, { hunk('untracked', 1, 3) })
        eq(placed, 3)
        local r = rows(bufnr)
        for i = 0, 2 do
          eq(signtext(r[i]), '┆')
          eq(r[i].sign_hl_group, 'VcssignUntracked')
        end
      end)
    end),
  },
  {
    name = 'the staged layer has its own namespace and does not disturb the worktree layer',
    fn = guarded(function()
      with_buf({ 'a', 'b', 'c' }, function(bufnr)
        signs.place(bufnr, { hunk('add', 1, 2) })
        signs.place(bufnr, { hunk('add', 1, 1) }, { staged = true })
        eq(signs.sign_count(bufnr, false), 2)
        eq(signs.sign_count(bufnr, true), 1)

        signs.clear_ns(bufnr, true)
        eq(signs.sign_count(bufnr, true), 0)
        eq(signs.sign_count(bufnr, false), 2)
      end)
    end),
  },
  {
    name = 'numhl writes number_hl_group for every type',
    fn = guarded(function()
      config.setup({ signs = { numhl = true } })
      with_buf({ 'a', 'b', 'c' }, function(bufnr)
        signs.place(bufnr, { hunk('add', 1, 1), hunk('delete', 0, 0, 3, 1) })
        local r = rows(bufnr)
        eq(r[0].number_hl_group, 'VcssignAddNr')
        eq(r[1].number_hl_group, 'VcssignDeleteNr')
      end)

      config.setup({ signs = { numhl = false } })
      with_buf({ 'a' }, function(bufnr)
        signs.place(bufnr, { hunk('add', 1, 1) })
        eq(rows(bufnr)[0].number_hl_group, nil)
      end)
    end),
  },
  {
    name = 'linehl writes line_hl_group except for the two delete types',
    fn = guarded(function()
      config.setup({ signs = { linehl = true } })
      with_buf({ 'a', 'b', 'c', 'd' }, function(bufnr)
        signs.place(bufnr, {
          hunk('add', 1, 1),
          hunk('change', 2, 1, 2, 1),
          hunk('changedelete', 3, 1),
          hunk('untracked', 4, 1),
        })
        local r = rows(bufnr)
        eq(r[0].line_hl_group, 'VcssignAddLn')
        eq(r[1].line_hl_group, 'VcssignChangeLn')
        eq(r[2].line_hl_group, 'VcssignChangeDeleteLn')
        eq(r[3].line_hl_group, 'VcssignUntrackedLn')
      end)

      with_buf({ 'a', 'b', 'c' }, function(bufnr)
        signs.place(bufnr, { hunk('delete', 0, 0, 3, 1), hunk('topdelete', 0, 0, 1, 1) })
        local r = rows(bufnr)
        eq(r[1].line_hl_group, nil)
        eq(r[0].line_hl_group, nil)
      end)
    end),
  },
  {
    name = 'place is a full re-render of its own namespace',
    fn = guarded(function()
      with_buf({ 'a', 'b', 'c', 'd' }, function(bufnr)
        signs.place(bufnr, { hunk('add', 1, 4) })
        eq(signs.sign_count(bufnr), 4)
        signs.place(bufnr, { hunk('add', 2, 1) })
        eq(signs.sign_count(bufnr), 1)
      end)
    end),
  },
  {
    name = 'a hunk past the end of the buffer is skipped, not an error',
    fn = guarded(function()
      with_buf({ 'a', 'b' }, function(bufnr)
        local placed = signs.place(bufnr, { hunk('add', 10, 1) })
        eq(placed, 0)
        eq(signs.sign_count(bufnr), 0)
      end)
    end),
  },
  {
    name = 'clear empties both layers',
    fn = guarded(function()
      with_buf({ 'a', 'b' }, function(bufnr)
        signs.place(bufnr, { hunk('add', 1, 1) })
        signs.place(bufnr, { hunk('add', 1, 1) }, { staged = true })
        signs.clear(bufnr)
        eq(signs.sign_count(bufnr, false), 0)
        eq(signs.sign_count(bufnr, true), 0)
      end)
    end),
  },
}
