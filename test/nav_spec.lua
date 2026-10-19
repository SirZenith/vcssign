--- M6 Step 8: hunk navigation (`]c` / `[c`) and the default keymaps around it.
---
--- The arithmetic is pinned with hand-built hunks — `attach.hunks` and
--- `attach.state` are stubbed, so a landing position is a fact about the
--- navigator rather than about git's diff — and one end-to-end case runs the
--- real pipeline so the anchors `nav` computes are the signs `attach` drew.
--- The last cases pin the keymap layer: buffer-local default maps, `keymaps =
--- false`, and what an action that does not exist yet answers.
local api = vim.api

local attach = require('vcssign.attach')
local config = require('vcssign.config')
local keymap = require('vcssign.keymap')
local manager = require('vcssign.repo_manager')
local nav = require('vcssign.nav')

local helpers = require('helpers')

--- The unstubbed accessors, captured once: `stub` below replaces them for the
--- duration of one case.
local real_hunks = attach.hunks
local real_state = attach.state

--- Show `hunks` (and `staged`) as this buffer's picture, with no repository.
---@param hunks vcssign.Hunk[]
---@param staged? vcssign.Hunk[]
local function stub(hunks, staged)
  attach.hunks = function()
    return hunks
  end
  attach.state = function()
    return { hunks_staged = staged or {} }
  end
end

local function unstub()
  attach.hunks = real_hunks
  attach.state = real_state
end

--- Buffers a case opened, so it can close them again (in `guarded`).
---@type table<integer, true>
local touched = {}

---@param bufnr integer
---@return integer
local function tracked(bufnr)
  touched[bufnr] = true
  return bufnr
end

--- Close everything a case touched, then reset the module state and the config.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    unstub()
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

--- A scratch buffer of `n` numbered lines, current in this window.
---@param n integer
---@return integer bufnr
local function scratch(n)
  local bufnr = api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n do
    lines[i] = 'line ' .. i
  end
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  api.nvim_set_current_buf(bufnr)
  return bufnr
end

--- An inserted / changed line at `lnum` (the shape `hunk.lua` builds).
---@param lnum integer
---@return vcssign.Hunk
local function add_hunk(lnum)
  return {
    added = { start = lnum, count = 1 },
    removed = { start = lnum > 1 and (lnum - 1) or 0, count = 0 },
    type = 'add',
  }
end

--- Open a real file and attach it (`attach_spec.lua`'s helper, inline).
---@param path string
---@return integer bufnr
local function open(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = tracked(api.nvim_get_current_buf())
  attach.attach(bufnr)
  helpers.wait_for(function()
    local st = attach.state(bufnr)
    return st ~= nil and st.attached and st.buf_text ~= nil
  end, 'the buffer to attach')
  return bufnr
end

---@param bufnr integer
---@param lnum integer
local function put_cursor(bufnr, lnum)
  api.nvim_set_current_buf(bufnr)
  api.nvim_win_set_cursor(0, { lnum, 0 })
end

---@return integer lnum
local function cursor()
  return api.nvim_win_get_cursor(0)[1]
end

--- The buffer-local keymap installed for `lhs`, if any.
---@param bufnr integer
---@param lhs string
---@return table?
local function mapping(bufnr, lhs)
  for _, m in ipairs(api.nvim_buf_get_keymap(bufnr, 'n')) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

return {
  {
    name = 'next lands on the first hunk after the cursor, strictly forward',
    fn = guarded(function()
      local bufnr = tracked(scratch(12))
      stub({ add_hunk(2), add_hunk(5), add_hunk(9) })
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 1), 2, 'from before the first hunk')
      eq(nav.next(bufnr, 1), 5, 'from the first hunk, not back to it')
      eq(nav.next(bufnr, 1), 9, 'from the second')
    end),
  },
  {
    name = 'prev mirrors next and lands on the last hunk before the cursor',
    fn = guarded(function()
      local bufnr = tracked(scratch(12))
      stub({ add_hunk(2), add_hunk(5), add_hunk(9) })
      put_cursor(bufnr, 12)
      eq(nav.prev(bufnr, 1), 9, 'from after the last hunk')
      eq(nav.prev(bufnr, 1), 5, 'from the last hunk')
      eq(nav.prev(bufnr, 1), 2, 'from the second')
      eq(nav.prev(bufnr, 1), 9, 'and it wraps around like ]c does')
    end),
  },
  {
    name = 'a single hunk is reached from everywhere, and pressing on is a no-op',
    fn = guarded(function()
      local bufnr = tracked(scratch(6))
      stub({ add_hunk(3) })
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 1), 3, ']c reaches it')
      eq(nav.next(bufnr, 1), nil, 'already there: no move')
      eq(cursor(), 3, 'and the column is left alone')
      put_cursor(bufnr, 6)
      eq(nav.prev(bufnr, 1), 3, '[c reaches it')
    end),
  },
  {
    name = 'a count crosses that many hunks, in both directions',
    fn = guarded(function()
      local bufnr = tracked(scratch(12))
      stub({ add_hunk(2), add_hunk(5), add_hunk(9) })
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 2), 5, '2]c skips the first hunk')
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 3), 9, '3]c lands on the third')
      put_cursor(bufnr, 9)
      eq(nav.prev(bufnr, 2), 2, '2[c')
      put_cursor(bufnr, 1)
      eq(nav.prev(bufnr, 2), 5, '2[c wraps: it counts hunks, not lines')
    end),
  },
  {
    name = 'the ends wrap around, and opts.wrap = false stops instead',
    fn = guarded(function()
      local bufnr = tracked(scratch(12))
      stub({ add_hunk(2), add_hunk(5), add_hunk(9) })
      put_cursor(bufnr, 10)
      eq(nav.next(bufnr, 1), 2, ']c past the last hunk wraps to the first')
      eq(nav.next(bufnr, 4), 5, 'a count longer than the list keeps wrapping')
      put_cursor(bufnr, 10)
      eq(nav.next(bufnr, 1, { wrap = false }), nil, 'wrap off: no move')
      eq(cursor(), 10, 'and the cursor is where it was')
      put_cursor(bufnr, 1)
      eq(nav.prev(bufnr, 1, { wrap = false }), nil, 'wrap off: no move backwards')
      eq(cursor(), 1, 'and the cursor is where it was')
      eq(nav.prev(bufnr, 1), 9, 'wrap on (the default) reaches the last hunk')
    end),
  },
  {
    name = 'a buffer with no hunks never moves the cursor',
    fn = guarded(function()
      local bufnr = tracked(scratch(6))
      stub({})
      put_cursor(bufnr, 3)
      eq(nav.next(bufnr, 1), nil, 'nothing to jump to')
      eq(nav.prev(bufnr, 1), nil, 'nothing to jump to')
      eq(cursor(), 3, 'the cursor has not moved')
      -- A hunk the buffer no longer has (it shrank before the debounced
      -- re-render) is not a landing spot either.
      stub({ add_hunk(40) })
      eq(nav.next(bufnr, 1), nil, 'no anchor inside the buffer')
      eq(cursor(), 3, 'the cursor has not moved')
    end),
  },
  {
    name = 'deletions anchor on the line above, top deletions on line 1',
    fn = guarded(function()
      local bufnr = tracked(scratch(10))
      stub({
        { added = { start = 0, count = 0 }, removed = { start = 4, count = 2 }, type = 'delete' },
        {
          added = { start = 0, count = 0 },
          removed = { start = 1, count = 3 },
          type = 'topdelete',
        },
      })
      eq(nav.lines(bufnr), { 1, 3 }, 'the sign lines, not the removed lines')
    end),
  },
  {
    name = 'the staged layer is a landing spot too',
    fn = guarded(function()
      local bufnr = tracked(scratch(10))
      stub({ add_hunk(8) }, { add_hunk(3) })
      eq(nav.lines(bufnr), { 3, 8 }, 'both layers, ascending')
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 1), 3, 'a staged-only hunk is found')
      eq(nav.prev(bufnr, 1), 8, 'and the worktree hunk behind it')
    end),
  },
  {
    name = 'the real pipeline lands on the signs it drew',
    fn = guarded(function()
      local dir = helpers.git_repo('nav_real')
      local lines = {}
      for i = 1, 20 do
        lines[i] = 'line ' .. i
      end
      helpers.write(dir .. '/base.txt', table.concat(lines, '\n') .. '\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'twenty lines' })
      lines[2] = 'line 2 changed'
      lines[18] = 'line 18 changed'
      helpers.write(dir .. '/base.txt', table.concat(lines, '\n') .. '\n')

      local bufnr = open(dir .. '/base.txt')
      eq(nav.lines(bufnr), { 2, 18 }, 'two hunks, on the lines that changed')
      put_cursor(bufnr, 1)
      eq(nav.next(bufnr, 1), 2, ']c from the top')
      eq(nav.next(bufnr, 1), 18, ']c again')
      eq(nav.next(bufnr, 1), 2, 'and it wraps')
      eq(nav.prev(bufnr, 1), 18, '[c wraps the other way')
    end),
  },
  {
    name = 'attaching installs the default keymaps for that buffer',
    fn = guarded(function()
      local dir = helpers.git_repo('nav_keys')
      local bufnr = open(dir .. '/base.txt')
      local configured = 0
      for _ in pairs(config.get().keymaps) do
        configured = configured + 1
      end
      eq(#api.nvim_buf_get_keymap(bufnr, 'n'), configured, 'one mapping per config key')
      local map = mapping(bufnr, ']c')
      ok(map ~= nil, ']c is mapped')
      eq(map.desc, 'vcssign next_hunk', 'and named after its action')
      ok(type(map.callback) == 'function', 'it runs a Lua callback')

      -- A clean file has no hunks, so the mapping has nothing to do; the real
      -- jump is covered above.  What matters here is the wiring.
      put_cursor(bufnr, 1)
      map.callback()
      eq(cursor(), 1, 'the mapping runs the action')
      attach.detach(bufnr)
      ok(mapping(bufnr, ']c') == nil, 'detaching removes the mappings again')
    end),
  },
  {
    name = 'the ]c mapping moves the cursor through the real hunks',
    fn = guarded(function()
      local dir = helpers.git_repo('nav_keys_run')
      helpers.write(dir .. '/base.txt', 'one\ntwo\nthree\nfour\nfive\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'five lines' })
      helpers.write(dir .. '/base.txt', 'one\ntwo\nTHREE\nfour\nfive\n')
      local bufnr = open(dir .. '/base.txt')
      put_cursor(bufnr, 1)
      local map = mapping(bufnr, ']c')
      ok(map ~= nil and type(map.callback) == 'function', 'the mapping is there')
      map.callback()
      eq(cursor(), 3, 'the mapping jumps to the hunk it drew')
    end),
  },
  {
    name = 'config.keymaps = false installs nothing',
    fn = guarded(function()
      config.setup({ keymaps = false })
      local dir = helpers.git_repo('nav_nokeys')
      local bufnr = open(dir .. '/base.txt')
      eq(#api.nvim_buf_get_keymap(bufnr, 'n'), 0, 'no buffer-local mappings')
    end),
  },
  {
    name = 'an action that does not exist yet answers instead of failing',
    fn = guarded(function()
      local dir = helpers.git_repo('nav_todo')
      local bufnr = open(dir .. '/base.txt')
      -- `setqflist` is the action signs §10 keeps on the backlog, so this case
      -- keeps its meaning for the rest of M6: whichever action is named here,
      -- pressing it twice must warn once and not blow up.
      local seen = helpers.capture_notify(function()
        keymap.dispatch('setqflist', { bufnr = bufnr })
        keymap.dispatch('setqflist', { bufnr = bufnr })
      end, function(s)
        return #helpers.select_notifications(s, 'setqflist') > 0
      end)
      local warnings = helpers.select_notifications(seen, 'setqflist')
      eq(#warnings, 1, 'one notice per action, not one per key press')
      ok(
        warnings[1].message:find('setqflist', 1, true) ~= nil,
        'it names the action: ' .. warnings[1].message
      )
      eq(warnings[1].level, vim.log.levels.WARN)
    end),
  },
}
