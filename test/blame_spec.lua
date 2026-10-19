--- M6 Step 11, realigned with gitsigns: current-line blame
--- (`config.current_line_blame`, keys `hb` / `tb`).
---
--- The formatting cases need no repository at all (see
--- `blame_formatter_spec.lua`); the rest run against a real repository and read
--- the extmarks, the `vim.b` record and the float, so what is pinned is what the
--- user sees, not how the adapter was called.
local api = vim.api

local actions = require('vcssign.actions')
local attach = require('vcssign.attach')
local blame = require('vcssign.blame')
local config = require('vcssign.config')
local exec = require('vcssign.exec')
local manager = require('vcssign.repo_manager')
local preview = require('vcssign.preview')

local helpers = require('helpers')

--- A deterministic format: gitsigns' default leans on `%R` (a relative date)
--- and on the object id, neither of which an assertion can spell out.
local FMT = ' <author> - <summary> '
local FMT_NC = ' Not Committed Yet '

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
---@param over? table<string, any>  extra `current_line_blame_opts`
local function enable_blame(over)
  config.setup({
    current_line_blame = true,
    current_line_blame_opts = vim.tbl_extend(
      'force',
      { delay = 1, virt_text_pos = 'eol' },
      over or {}
    ),
    current_line_blame_formatter = FMT,
    current_line_blame_formatter_nc = FMT_NC,
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

--- Every `blame` command `fn` runs, as argv strings (08 P1-3).
---
--- `count_blames` above answers "how many"; this answers "which window", which
--- is the claim that matters: a look at one line must not blame the file.
---@param fn function
---@return string[]
local function blame_commands(fn)
  local real_run = exec.run
  local calls = {}
  exec.run = function(cmd, opts, cb)
    local joined = table.concat(cmd, ' ')
    if joined:find('blame', 1, true) then
      calls[#calls + 1] = joined
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
  return {
    rev = rev,
    author = 'Ada Lovelace',
    author_name = 'Ada Lovelace',
    author_time = time,
    time = time,
    summary = 'add the thing',
  }
end

return {
  {
    name = 'a committed line is formatted through current_line_blame_formatter',
    fn = guarded(function() --[[ no repository needed ]]
      config.setup({
        current_line_blame_formatter = ' <author_name> <author_time:%Y-%m-%d> - <summary> ',
      })
      local bl =
        line(string.rep('abcdef12', 5), os.time({ year = 2020, month = 1, day = 2, hour = 12 }))
      eq(
        blame.commit_text(bl),
        'abcdef12 Ada Lovelace 2020-01-02',
        'the commit without its subject'
      )
      eq(
        blame.line_text(bl),
        ' Ada Lovelace 2020-01-02 - add the thing ',
        'the configured format, placeholders expanded'
      )
      -- A VCS that reports neither a subject nor a commit date (svn does have
      -- dates; this is the shape of a line it cannot attribute) still formats.
      eq(
        blame.line_text({ rev = '41', author = 'Ada' }, { has_summary = false }),
        ' Ada <author_time:%Y-%m-%d> - <summary> ',
        'every placeholder the adapter cannot answer stays visible'
      )
    end),
  },
  {
    name = 'a line with no commit behind it says so instead of blaming a zero sha',
    fn = guarded(function()
      eq(
        blame.line_text({ rev = string.rep('0', 40), author = 'Not Committed Yet' }),
        FMT_NC,
        'git: an all-zero sha'
      )
      eq(blame.line_text({ rev = '-', author = '-' }), FMT_NC, 'svn: no <commit>')
      -- commit_text is what the float shows, so it stays the human summary.
      eq(blame.commit_text({ rev = '-', author = '-' }), 'Not Committed Yet')
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
      eq(vim.b[bufnr].vcssign_blame_line, ' t - three lines ', 'the text is kept in vim.b')
      ok(
        vim.b[bufnr].vcssign_blame_line_dict.abbrev_sha:match('^%x+$'),
        'and the fields behind it too'
      )

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
    name = 'virt_text = false keeps the annotation out of the buffer',
    fn = guarded(function()
      enable_blame({ virt_text = false })
      local dir = helpers.git_repo('blame-novirt')
      local bufnr = open_attached(dir .. '/base.txt')

      move_to(bufnr, 1)
      helpers.wait_for(function()
        return vim.b[bufnr].vcssign_blame_line ~= nil
      end, 'the annotation text')
      eq(marked_rows(bufnr), {}, 'no extmark is written')
      eq(vim.b[bufnr].vcssign_blame_line, ' t - init ', 'the text is still available')
    end),
  },
  {
    name = 'ignore_whitespace blames through a whitespace-only change',
    fn = guarded(function()
      local dir = helpers.git_repo('blame-ws')
      -- A whitespace-only change *in the working copy* (`base` -> `  base`):
      -- `git blame` reads the file, so the buffer is not what has to change.
      helpers.write(dir .. '/base.txt', '  base')
      local bufnr = open_attached(dir .. '/base.txt')

      enable_blame({ ignore_whitespace = true })
      blame.render(bufnr)
      helpers.wait_for(function()
        return vim.b[bufnr].vcssign_blame_line == ' t - init '
      end, 'the annotation of the committed line')

      -- Without `-w` the same line is nobody's yet.
      enable_blame()
      blame.render(bufnr)
      helpers.wait_for(function()
        return vim.b[bufnr].vcssign_blame_line == FMT_NC
      end, 'the uncommitted annotation')
    end),
  },
  {
    name = 'use_focus keeps an unfocused window bare',
    fn = guarded(function()
      enable_blame()
      local dir = helpers.git_repo('blame-focus')
      local bufnr = open_attached(dir .. '/base.txt')
      move_to(bufnr, 1)
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the annotation of the focused window')

      -- A second window on another buffer takes the focus.
      vim.cmd('vsplit')
      vim.cmd('enew')
      local other = api.nvim_get_current_buf()
      touched[other] = true
      blame.clear(bufnr)
      blame.render(bufnr)
      vim.wait(60)
      eq(marked_rows(bufnr), {}, 'an unfocused window is left alone')
      eq(marked_rows(bufnr), {}, 'an unfocused window is left alone')

      -- With `use_focus` off, the same render draws.
      enable_blame({ use_focus = false })
      blame.setup() -- what `toggle_current_line_blame` does for the user
      blame.render(bufnr)
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the annotation once the focus does not matter')
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
      enable_blame()
      move_to(bufnr, 1)
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 1
      end, 'the decoration to appear')

      local notification = helpers.capture_notify_one(function()
        actions.toggle_current_line_blame()
      end, 'blame off')
      eq(notification.message, 'vcssign: blame off', 'turning it off says so')
      helpers.wait_for(function()
        return #marked_rows(bufnr) == 0
      end, 'the decoration to go')
      eq(vim.b[bufnr].vcssign_blame_line, nil, 'and the text goes with it')

      local back = helpers.capture_notify_one(function()
        actions.toggle_current_line_blame()
      end, 'blame on')
      eq(back.message, 'vcssign: blame on')
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
      eq(#seen, 0, 'showing a float says nothing: ' .. helpers.describe_notifications(seen))
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
    name = 'a line is blamed once, and going back to it costs nothing',
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

      -- Line 2 has not been asked about yet: the cache is per line, so this is
      -- one process (08 P1-3 asks for `-L l,l`, not the whole file).
      local calls = count_blames(function()
        move_to(bufnr, 2)
        helpers.wait_for(function()
          return vim.deep_equal(marked_rows(bufnr), { 1 })
        end, 'the decoration on line 2')
      end)
      eq(calls, 1, 'the line that was never looked at is blamed once')

      -- And it stays: moving back is a cache hit.
      local again = count_blames(function()
        move_to(bufnr, 1)
        helpers.wait_for(function()
          return vim.deep_equal(marked_rows(bufnr), { 0 })
        end, 'the decoration back on line 1')
      end)
      eq(again, 0, 'going back to a blamed line costs nothing')

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
    name = 'the blame of a line asks for that line, not the whole file',
    fn = guarded(function()
      enable_blame()
      local dir = helpers.git_repo('blame-window')
      helpers.write(dir .. '/base.txt', 'one\ntwo\nthree\nfour\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'four lines' })
      local bufnr = open_attached(dir .. '/base.txt')
      local cmds = blame_commands(function()
        move_to(bufnr, 3)
        helpers.wait_for(function()
          return #marked_rows(bufnr) == 1
        end, 'the decoration on line 3')
      end)
      eq(#cmds, 1, 'one process')
      ok(cmds[1]:find('-L 3,3', 1, true) ~= nil, 'the window is the line asked about: ' .. cmds[1])
      eq(vim.b[bufnr].vcssign_blame_line, ' t - four lines ', 'and it answers')
    end),
  },
  {
    name = 'a commit retires the cached answer, because the baseline moved',
    fn = guarded(function()
      enable_blame()
      local dir = helpers.git_repo('blame-stamp')
      helpers.write(dir .. '/base.txt', 'alpha\n')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'first' })
      -- A worktree line nobody has committed yet.
      helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
      local bufnr = open_attached(dir .. '/base.txt')
      move_to(bufnr, 2)
      helpers.wait_for(function()
        return vim.b[bufnr].vcssign_blame_line == ' Not Committed Yet '
      end, 'the not-committed annotation')

      -- The buffer's text does not move: only the store does, so the
      -- `changedtick` in the cache key cannot see this (08 P1-3).
      helpers.sh({ 'git', '-C', dir, 'add', '-A' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'second' })
      local calls = count_blames(function()
        blame.render(bufnr)
        helpers.wait_for(function()
          return vim.b[bufnr].vcssign_blame_line == ' t - second '
        end, 'the committed annotation')
      end)
      eq(calls, 1, 'the answer was fetched again instead of being trusted')
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
      eq(#seen, 0, 'showing a float says nothing: ' .. helpers.describe_notifications(seen))
      local text = float_lines()
      ok(text ~= nil, 'the float is open')
      eq(text[1], 'Not Committed Yet')
      eq(text[2], 'new', 'and the line itself')
    end),
  },
}
