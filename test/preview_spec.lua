--- M6 Step 10: the hunk preview (`hp`) and the deleted-line preview
--- (`config.deleted_preview`).
---
--- `hunk_text` and the anchoring of the virtual lines are pinned with
--- hand-built hunks; the last two cases open a real preview window, one without
--- a repository and one through the `hp` mapping.
local api = vim.api

local attach = require('vcssign.attach')
local config = require('vcssign.config')
local keymap = require('vcssign.keymap')
local manager = require('vcssign.repo_manager')
local preview = require('vcssign.preview')

local helpers = require('helpers')

--- Buffers a case opened, so it can close them again (in `guarded`).
---@type table<integer, true>
local touched = {}

--- Close what a case touched, then reset the module state and the config.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    preview.close()
    for bufnr in pairs(touched) do
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    touched = {}
    attach.forget_all()
    manager.dispose_all()
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- A scratch buffer holding `lines`.
---@param lines string[]
---@return integer bufnr
local function buffer(lines)
  local bufnr = api.nvim_create_buf(false, true)
  touched[bufnr] = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- A change hunk: `removed_count` baseline lines replaced by `added_count`
--- buffer lines.
local function change(removed_start, removed_count, added_start, added_count)
  return {
    added = { start = added_start, count = added_count },
    removed = { start = removed_start, count = removed_count },
    type = 'change',
  }
end

--- The deleted-line previews of one buffer, in extmark order.
---@param bufnr integer
local function virt(bufnr)
  local out = {}
  for _, m in
    ipairs(api.nvim_buf_get_extmarks(bufnr, preview.namespace(), 0, -1, { details = true }))
  do
    local details = m[4]
    if details.virt_lines then
      local text, hl = {}, {}
      for _, chunk in ipairs(details.virt_lines) do
        text[#text + 1] = chunk[1][1]
        hl[#hl + 1] = chunk[1][2]
      end
      out[#out + 1] = { row = m[2], above = details.virt_lines_above, text = text, hl = hl }
    end
  end
  return out
end

--- The one floating window, if it is open.
---@return integer? win
local function float_win()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= '' then
      return win
    end
  end
  return nil
end

return {
  {
    name = 'a hunk reads as a unified diff, header and all',
    fn = guarded(function()
      eq(
        preview.hunk_text(change(2, 1, 2, 1), { 'a', 'old' }, { 'a', 'new' }),
        { '@@ -2,1 +2,1 @@', '-old', '+new' }
      )
      local added =
        { added = { start = 2, count = 2 }, removed = { start = 1, count = 0 }, type = 'add' }
      eq(preview.hunk_text(added, { '' }, { 'a', 'x', 'y' }), { '@@ -1,0 +2,2 @@', '+x', '+y' })
      eq(
        preview.hunk_text(
          { added = { start = 1, count = 0 }, removed = { start = 2, count = 2 }, type = 'delete' },
          { 'a', 'g1', 'g2' },
          { 'a' }
        ),
        { '@@ -2,2 +1,0 @@', '-g1', '-g2' }
      )
    end),
  },
  {
    name = 'the deleted lines of a delete hunk show below the line the sign marks',
    fn = guarded(function()
      config.setup({ deleted_preview = true })
      local bufnr = buffer({ 'a', 'd' })
      -- The baseline held two more lines between those two.
      local h =
        { added = { start = 1, count = 0 }, removed = { start = 2, count = 2 }, type = 'delete' }
      eq(preview.render_deleted(bufnr, { h }, { 'a', 'g1', 'g2', 'd' }, { 'a', 'd' }), 1)
      local marks = virt(bufnr)
      eq(#marks, 1)
      eq(marks[1].row, 0, 'on the line above the removed block, where the sign is')
      ok(not marks[1].above, 'shown below that line')
      eq(marks[1].text, { 'g1', 'g2' })
      eq(marks[1].hl, { 'VcssignDeleteVirtLn', 'VcssignDeleteVirtLn' })
    end),
  },
  {
    name = 'a topdelete has nowhere above it, so its lines go above line 1',
    fn = guarded(function()
      config.setup({ deleted_preview = true })
      local bufnr = buffer({ 'a' })
      local h =
        { added = { start = 1, count = 0 }, removed = { start = 1, count = 1 }, type = 'topdelete' }
      eq(preview.render_deleted(bufnr, { h }, { 'g1', 'a' }, { 'a' }), 1)
      local marks = virt(bufnr)
      eq(marks[1].row, 0)
      eq(marks[1].above, true)
      eq(marks[1].text, { 'g1' })
    end),
  },
  {
    name = 'a change shows only the lines it removed without replacing them',
    fn = guarded(function()
      config.setup({ deleted_preview = true })
      local bufnr = buffer({ 'a2' })
      -- Three baseline lines became one: the first is the change (the word diff
      -- compares it), the other two are the ones the reader cannot see anymore.
      eq(preview.render_deleted(bufnr, { change(1, 3, 1, 1) }, { 'a', 'g1', 'g2' }, { 'a2' }), 1)
      local marks = virt(bufnr)
      eq(marks[1].text, { 'g1', 'g2' })
      eq(marks[1].row, 0, 'anchored on the last added line')
      ok(not marks[1].above)
    end),
  },
  {
    name = 'the deleted-line preview is off by default',
    fn = guarded(function()
      local bufnr = buffer({ 'a', 'd' })
      local h =
        { added = { start = 1, count = 0 }, removed = { start = 2, count = 2 }, type = 'delete' }
      eq(preview.render_deleted(bufnr, { h }, { 'a', 'g1', 'g2', 'd' }, { 'a', 'd' }), 0)
      eq(virt(bufnr), {})
    end),
  },
  {
    name = 'the hunk preview opens once, toggles closed and follows the cursor',
    fn = guarded(function()
      local bufnr = buffer({ 'a', 'new' })
      local h = change(2, 1, 2, 1)
      local base, lines = { 'a', 'old' }, { 'a', 'new' }

      eq(preview.toggle_hunk(bufnr, h, 2, base, lines), true)
      ok(preview.is_open(bufnr, 2))
      local win = float_win()
      ok(win ~= nil, 'a floating window')
      local pbuf = api.nvim_win_get_buf(win)
      eq(api.nvim_buf_get_lines(pbuf, 0, -1, false), preview.hunk_text(h, base, lines))
      eq(vim.bo[pbuf].filetype, 'diff', 'so the colorscheme colours the lines')
      ok(not vim.bo[pbuf].modifiable, 'and nobody edits it')

      -- The same hunk again: the action is a toggle, not a second window.
      eq(preview.toggle_hunk(bufnr, h, 2, base, lines), false)
      ok(not preview.is_open(bufnr, 2))
      eq(float_win(), nil)

      -- Another line opens it again, and the cursor leaving that line closes it.
      eq(preview.toggle_hunk(bufnr, h, 1, base, lines), true)
      api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })
      ok(not preview.is_open(bufnr, 1), 'closed by CursorMoved')
      eq(float_win(), nil)
    end),
  },
  {
    name = 'the hp mapping previews the hunk under the cursor',
    fn = guarded(function()
      local dir = helpers.git_repo('preview-repo')
      helpers.write(dir .. '/base.txt', 'changed\nsecond\n')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
      local bufnr = api.nvim_get_current_buf()
      touched[bufnr] = true
      attach.attach(bufnr)
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to attach')

      keymap.dispatch('preview_hunk', { bufnr = bufnr })
      helpers.wait_for(function()
        return preview.is_open(bufnr)
      end, 'the preview to open')
      local win = float_win()
      local lines = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
      eq(lines[1], '@@ -1,1 +1,2 @@')
      ok(vim.tbl_contains(lines, '-base'), 'the baseline line')
      ok(vim.tbl_contains(lines, '+changed'), 'and what replaced it')

      -- Pressing the same key again closes it.
      keymap.dispatch('preview_hunk', { bufnr = bufnr })
      ok(not preview.is_open(bufnr), 'the second press closes it')
    end),
  },
}
