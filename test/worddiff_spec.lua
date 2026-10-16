--- M6 Step 10: the inline word diff (`config.word_diff`, keymap `tw`).
---
--- The ranges are pinned with two strings and no buffer, so what counts as a
--- "word" and where a range starts are facts about `worddiff.ranges` rather
--- than about git; the last case runs the switch against a real repository.
local api = vim.api

local attach = require('vcssign.attach')
local config = require('vcssign.config')
local keymap = require('vcssign.keymap')
local manager = require('vcssign.repo_manager')
local worddiff = require('vcssign.worddiff')

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

--- The inline ranges of one buffer, as 0-based rows and byte columns.
---@param bufnr integer
local function marks(bufnr)
  local out = {}
  for _, m in
    ipairs(api.nvim_buf_get_extmarks(bufnr, worddiff.namespace(), 0, -1, { details = true }))
  do
    out[#out + 1] = { row = m[2], start = m[3], stop = m[4].end_col }
  end
  return out
end

return {
  {
    name = 'the diff of a line is the token that changed, not the whole line',
    fn = guarded(function()
      eq(worddiff.ranges('local a = 1', 'local abc = 1'), { { 6, 9 } }, "the word 'a' became 'abc'")
      eq(worddiff.ranges('x, y', 'x; y'), { { 1, 2 } }, 'the comma became a semicolon')
      eq(worddiff.ranges('a b c', 'A b C'), { { 0, 1 }, { 4, 5 } }, 'two separate changes')
    end),
  },
  {
    name = 'a line that did not change has no ranges',
    fn = guarded(function()
      eq(worddiff.ranges('a = 1', 'a = 1'), {})
      eq(worddiff.ranges('', ''), {})
    end),
  },
  {
    name = 'a removal with nothing left on the new side is not a range',
    fn = guarded(function()
      -- `1 2` -> `1`: the tokens disappear, and there is nothing in the new
      -- line to paint — the sign (or the deleted-line preview) says it instead.
      eq(worddiff.ranges('a = 1 2', 'a = 1'), {})
    end),
  },
  {
    name = 'non-ASCII text is diffed per character, in bytes',
    fn = guarded(function()
      -- Three bytes per character, so the second character is bytes 3..6.
      eq(worddiff.ranges('一二', '一三'), { { 3, 6 } })
    end),
  },
  {
    name = 'an indentation change is a range like any other',
    fn = guarded(function()
      eq(worddiff.ranges('  a', '    a'), { { 0, 4 } })
    end),
  },
  {
    name = 'render highlights the paired lines of a change hunk',
    fn = guarded(function()
      config.setup({ word_diff = true })
      local bufnr = buffer({ 'local abc = 1' })
      local placed = worddiff.render(
        bufnr,
        { change(1, 1, 1, 1) },
        { 'local a = 1' },
        { 'local abc = 1' }
      )
      eq(placed, 1, 'one range')
      eq(marks(bufnr), { { row = 0, start = 6, stop = 9 } })
    end),
  },
  {
    name = 'render is off by default, and ignores hunks with nothing to pair',
    fn = guarded(function()
      local bufnr = buffer({ 'local abc = 1' })
      eq(
        worddiff.render(bufnr, { change(1, 1, 1, 1) }, { 'local a = 1' }, { 'local abc = 1' }),
        0,
        'off by default'
      )
      eq(marks(bufnr), {})

      config.setup({ word_diff = true })
      local added = {
        added = { start = 1, count = 1 },
        removed = { start = 0, count = 0 },
        type = 'add',
      }
      eq(
        worddiff.render(bufnr, { added }, { '' }, { 'local abc = 1' }),
        0,
        'an add hunk has no counterpart'
      )
      eq(marks(bufnr), {})
    end),
  },
  {
    name = 'render pairs the n-th removed line with the n-th added one',
    fn = guarded(function()
      config.setup({ word_diff = true })
      local bufnr = buffer({ 'a = 2' })
      -- Two baseline lines, one buffer line: only the first pair is compared,
      -- the surplus line is what the deleted-line preview would show.
      local placed = worddiff.render(
        bufnr,
        { change(1, 2, 1, 1) },
        { 'a = 1', 'b = 2' },
        { 'a = 2' }
      )
      eq(placed, 1)
      eq(marks(bufnr), { { row = 0, start = 4, stop = 5 } })
    end),
  },
  {
    name = 'the tw switch turns the inline diff on and renders it',
    fn = guarded(function()
      local dir = helpers.git_repo('worddiff-repo')
      helpers.write(dir .. '/base.txt', 'based\n')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
      local bufnr = api.nvim_get_current_buf()
      touched[bufnr] = true
      attach.attach(bufnr)
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to attach')

      eq(#marks(bufnr), 0, 'off by default')
      local seen = helpers.capture_notify(function()
        keymap.dispatch('toggle_word_diff', { bufnr = bufnr })
      end)
      eq(config.get().word_diff, true)
      ok(#seen > 0 and seen[1].message:find('word diff on', 1, true) ~= nil, 'the switch says so')

      -- The switch re-renders every attached buffer, which re-reads the
      -- baseline first: the ranges arrive with that answer.
      helpers.wait_for(function()
        return #marks(bufnr) > 0
      end, 'the inline diff to render')
      eq(marks(bufnr), { { row = 0, start = 0, stop = 5 } }, 'the whole changed word')
    end),
  },
}
