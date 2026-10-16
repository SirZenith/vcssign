--- M6 Step 11: current-line blame (`config.current_line_blame`, keys `hb` /
--- `tb`).
---
--- The formatting cases need no repository at all: what a line of blame *says*
--- is the formatting table's business.  The rest run against a real repository
--- and read the extmarks and the float, so what is pinned is what the user
--- sees, not how the adapter was called.
local api = vim.api

local actions = require('vcssign.actions')
local attach = require('vcssign.attach')
local blame = require('vcssign.blame')
local config = require('vcssign.config')
local exec = require('vcssign.exec')
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
    for bufnr in pairs(touched) do
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    touched = {}
    preview.close()
    attach.forget_all()
    manager.dispose_all()
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- Turn the decoration on with the shortest delay the timer accepts.
local function enable_blame()
  config.setup({
    current_line_blame = true,
    current_line_blame_opts = { delay = 1, virt_text_pos = 'eol' },
  })
end

--- A buffer showing `path`, attached and rendered.
---@param path string
---@return integer bufnr
local function open_attached(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = api.nvim_get_current_buf()
  touched[bufnr] = true
  attach.attach(bufnr)
  helpers.wait_for(function()
    local st = attach.state(bufnr)
    return st ~= nil and st.attached and st.buf_text ~= nil
  end, 'the buffer to attach')
  return bufnr
end

--- The rows (0-based) the inline blame is drawn on.
---@param bufnr integer
---@return integer[]
local function marked_rows(bufnr)
  local rows = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(bufnr, blame.namespace(), 0, -1, {})) do
    rows[#rows + 1] = m[2]
  end
  return rows
end

--- Put the cursor on `lnum` in the window showing `bufnr`, the way a person
--- would.
---
--- `nvim_win_set_cursor` does not fire `CursorMoved` in a headless session
--- (nothing does, unless it is asked to), so the event is raised by hand: the
--- autocmd the decoration hangs off is part of what these cases cover.
---@param bufnr integer
---@param lnum integer
local function move_to(bufnr, lnum)
  local win = vim.fn.bufwinid(bufnr)
  ok(win ~= -1, 'the buffer is on screen')
  api.nvim_win_set_cursor(win, { lnum, 0 })
  api.nvim_exec_autocmds('CursorMoved', { buffer = bufnr })
end

--- The lines of the floating window that is open, or nil.
---
--- A float is not in `bufwinid()`'s list (it has no window *slot*), so it is
--- found by its window configuration instead.
---@return string[]?
local function float_lines()
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(win).relative ~= '' then
      return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false)
    end
  end
  return nil
end

--- How many `blame` processes `fn` runs.
---@param fn function
---@return integer
local function count_blames(fn)
  local real_run = exec.run
  local calls = 0
  exec.run = function(cmd, opts, cb)
    if table.concat(cmd, ' '):find('blame', 1, true) then
      calls = calls + 1
    end
    return real_run(cmd, opts, cb)
  end
  local ok, err = pcall(fn)
  exec.run = real_run
  if not ok then
    error(err, 0)
  end
  return calls
end

---@param rev string
---@param time integer?
---@return vcssign.BlameLine
local function line(rev, time)
  return { rev = rev, author = 'Ada Lovelace', time = time, summary = 'add the thing' }
end

return {
  {
    name = 'a committed line is blamed as its revision, author, date and subject',
    fn = guarded(function() --[[ no repository needed ]]
      local bl =
        line(string.rep('abcdef12', 5), os.time({ year = 2020, month = 1, day = 2, hour = 12 }))
      eq(
        blame.commit_text(bl),
        'abcdef12 Ada Lovelace 2020-01-02',
        'the commit without its subject'
      )
      eq(
        blame.line_text(bl),
        'abcdef12 Ada Lovelace 2020-01-02 add the thing',
        'the inline form appends the subject'
      )
      -- svn reports a short numeric revision and no subject at all.
      eq(
        blame.line_text({ rev = '41', author = 'Ada' }),
        '41 Ada',
        'a numeric revision stays whole'
      )
    end),
  },
  {
    name = 'a line with no commit behind it says so instead of blaming a zero sha',
    fn = guarded(function()
      eq(
        blame.line_text({ rev = string.rep('0', 40), author = 'Not Committed Yet' }),
        'Not Committed Yet',
        'git: an all-zero sha'
      )
      eq(blame.line_text({ rev = '-', author = '-' }), 'Not Committed Yet', 'svn: no <commit>')
    end),
  },
  {
    name = 'the inline decoration follows the cursor, one line at a time',
    fn = guarded(function()
      enable_blame()
      local dir = helpers.git_repo('blame-inline')
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\ngamma\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'three lines' })
      local bufnr = open_attached(dir .. '/base.txt')

      move_to(bufnr, 1)
      helpers.wait_for(function()
        return vim.deep_equal(marked_rows(bufnr), { 0 })
      end, 'the blame of line 1')

      move_to(bufnr, 3)
      helpers.wait_for(function()
        return vim.deep_equal(marked_rows(bufnr), { 2 })
      end, 'the blame moved to line 3 and left line 1 alone')
    end),
  },
  {
    name = 'nothing is drawn while the switch is off, and nothing is blamed',
    fn = guarded(function()
      local dir = helpers.git_repo('blame-off')
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'two lines' })
      local bufnr = open_attached(dir .. '/base.txt')
      move_to(bufnr, 1)

      local calls = count_blames(function()
        blame.render(bufnr)
        vim.wait(50)
      end)
      eq(calls, 0, 'a render with the feature off runs no command')
      eq(marked_rows(bufnr), {}, 'and draws nothing')
    end),
  },
  {
    name = 'the switch turns the decoration on and off, and says which way',
    fn = guarded(function()
      local dir = helpers.git_repo('blame-toggle')
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'two lines' })
      local bufnr = open_attached(dir .. '/base.txt')
      move_to(bufnr, 1)
      enable_blame()
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the decoration to appear')

      local seen = helpers.capture_notify(function()
        actions.toggle_current_line_blame()
      end)
      eq(seen[1].message, 'vcssign: blame off', 'turning it off says so')
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 0
      end, 'the decoration to go')

      local back = helpers.capture_notify(function()
        actions.toggle_current_line_blame()
      end)
      eq(back[1].message, 'vcssign: blame on')
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the decoration to come back')
    end),
  },
  {
    name = 'blame_line shows the commit and the line in a float, and takes it away again',
    fn = guarded(function()
      local dir = helpers.git_repo('blame-float')
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'two lines' })
      local bufnr = open_attached(dir .. '/base.txt')

      local seen = helpers.capture_notify(function()
        actions.blame_line(nil, { bufnr = bufnr, lnum = 1 })
        helpers.wait_for(function()
          return preview.is_open(bufnr, 1)
        end, 'the blame float')
      end)
      eq(#seen, 0, 'showing a float says nothing')
      local text = float_lines()
      ok(text ~= nil, 'the float is open')
      ok(text[1]:match('^%x+ t %d%d%d%d%-%d%d%-%d%d$'), 'the commit, then the source line')
      eq(text[2], 'two lines', 'the subject')
      eq(text[3], 'alpha', 'and the line itself')

      -- The same key on the same line is a toggle.
      actions.blame_line(nil, { bufnr = bufnr, lnum = 1 })
      ok(not preview.is_open(bufnr, 1), 'the second press closes it')
    end),
  },
  {
    name = 'a file is blamed once and reused while its text stands still',
    fn = guarded(function()
      enable_blame()
      local dir = helpers.git_repo('blame-cache')
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'two lines' })
      local bufnr = open_attached(dir .. '/base.txt')
      move_to(bufnr, 1)
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the first decoration')

      local calls = count_blames(function()
        move_to(bufnr, 2)
        helpers.wait_for(function()
          return vim.deep_equal(marked_rows(bufnr), { 1 })
        end, 'the decoration on line 2')
      end)
      eq(calls, 0, 'moving the cursor reuses the cached blame')

      -- The text changed: the next render asks again.
      local after_edit = count_blames(function()
        api.nvim_buf_set_lines(bufnr, 2, 2, false, { 'delta' })
        blame.render(bufnr)
        helpers.wait_for(function()
          return #marked_rows(bufnr) >= 1
        end, 'the decoration after an edit')
      end)
      eq(after_edit, 1, 'an edit invalidates the cache')
    end),
  },
  {
    name = 'a line that svn has not committed is not blamed on a revision',
    fn = guarded(function()
      local dir = helpers.svn_checkout('blame-svn')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open_attached(dir .. '/base.txt')

      local seen = helpers.capture_notify(function()
        actions.blame_line(nil, { bufnr = bufnr, lnum = 2 })
        helpers.wait_for(function()
          return preview.is_open(bufnr, 2)
        end, 'the blame float')
      end)
      eq(#seen, 0, 'showing a float says nothing')
      local text = float_lines()
      ok(text ~= nil, 'the float is open')
      eq(text[1], 'Not Committed Yet')
      eq(text[2], 'new', 'and the line itself')
    end),
  },
}
