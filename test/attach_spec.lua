--- M6 Step 5–7: the per-buffer attach pipeline, end to end on real repositories.
---
--- `signs_spec` pins the placement rules with no repository; this spec pins the
--- pipeline around them: detection through `repo_manager`, the baseline shown
--- from the index, the debounced re-render, the guards (too long / unnamed /
--- gone from disk), the per-buffer on/off switch (Step 6), the second (staged)
--- layer git gets (Step 7) and the release of the repository reference on
--- detach.
local api = vim.api

local attach = require('vcssign.attach')
local config = require('vcssign.config')
local exec = require('vcssign.exec')
local manager = require('vcssign.repo_manager')
local signs = require('vcssign.signs')

local helpers = require('helpers')

--- Clean up whether the case passed or failed, and reset any config override.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    attach.forget_all()
    manager.dispose_all()
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- Open a real file in the current window; returns its buffer and window.
---@param path string
---@return integer bufnr
---@return integer win
local function open(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  return api.nvim_get_current_buf(), api.nvim_get_current_win()
end

--- Attach and wait for detection *and* the first render to land (detection runs
--- VCS commands, and `st.attached` is set before the baseline arrives).
---@param bufnr integer
---@return vcssign.AttachState
local function attach_now(bufnr)
  attach.attach(bufnr)
  helpers.wait_for(function()
    local st = attach.state(bufnr)
    if not st then
      return false
    end
    if st.enabled == false then
      return true
    end
    return st.attached and st.buf_text ~= nil
  end, 'the buffer to attach')
  return attach.state(bufnr)
end

--- `refresh` reports through a callback: use it to synchronise exactly.
---@param bufnr integer
local function refresh_now(bufnr)
  return helpers.wait(function(cb)
    attach.refresh(bufnr, cb)
  end)
end

--- 0-based row -> extmark details of the worktree layer.
---@param bufnr integer
---@return table<integer, table>
local function rows(bufnr)
  local out = {}
  for _, mark in
    ipairs(api.nvim_buf_get_extmarks(bufnr, signs.namespace(false), 0, -1, { details = true }))
  do
    out[mark[2]] = mark[4]
  end
  return out
end

--- 0-based row -> extmark details of the staged (index) layer.
---@param bufnr integer
---@return table<integer, table>
local function staged_rows(bufnr)
  local out = {}
  for _, mark in
    ipairs(api.nvim_buf_get_extmarks(bufnr, signs.namespace(true), 0, -1, { details = true }))
  do
    out[mark[2]] = mark[4]
  end
  return out
end

--- Count how many *liveness probes* `fn` triggers (`repo_spec.lua:27` pattern).
---@param fn fun()
---@return integer
local function count_probes(fn)
  local real_run = exec.run
  local calls = 0
  exec.run = function(cmd, opts, cb)
    local joined = table.concat(cmd, ' ')
    if joined:find('rev-parse', 1, true) or joined:find('wc-root', 1, true) then
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

return {
  {
    name = 'attach draws a sign on the modified line',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-basic')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      ok(st.attached, 'the buffer must be attached')
      eq(st.root, dir)
      eq(st.system.name, 'git')
      ok(signs.sign_count(bufnr) > 0, 'a sign must be drawn')
      eq(attach.hunks(bufnr)[1].added.start, 2)
      eq(vim.trim(rows(bufnr)[1].sign_text or ''), '▎')
    end),
  },
  {
    name = 'the sign is visible in the sign column',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-visible')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr, win = open(dir .. '/base.txt')

      attach_now(bufnr)
      local line = helpers.screen_line_at(win, 2)
      ok(line:find('▎', 1, true), 'line 2 must show the sign, got: ' .. line)
    end),
  },
  {
    name = 'refresh follows the lines after the buffer changes',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-refresh')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      attach_now(bufnr)
      ok(rows(bufnr)[1], 'line 2 starts out added')

      -- Insert a line above: the earlier addition moves down one line.
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'x', 'base', 'new' })
      refresh_now(bufnr)

      local marked = rows(bufnr)
      eq(marked[1], nil, 'the old line 2 is unchanged now')
      ok(marked[0], 'the inserted line 1 is added')
      ok(marked[2], 'the addition moved to line 3')
      eq(attach.hunks(bufnr)[2].added.start, 3)
    end),
  },
  {
    name = 'an untracked file shows the untracked sign on every line',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-untracked')
      helpers.write(dir .. '/u.txt', 'a\nb\n')
      local bufnr = open(dir .. '/u.txt')

      local st = attach_now(bufnr)
      ok(st.attached, 'an untracked file still attaches')
      ok(st.untracked, 'and is marked untracked')
      eq(signs.sign_count(bufnr), 2)
      eq(vim.trim(rows(bufnr)[0].sign_text or ''), '┆')
      eq(vim.trim(rows(bufnr)[1].sign_text or ''), '┆')
    end),
  },
  {
    name = 'attach_to_untracked=false leaves an untracked file bare',
    fn = guarded(function()
      config.setup({ attach_to_untracked = false })
      local dir = helpers.git_repo('attach-untracked-off')
      helpers.write(dir .. '/u.txt', 'a\nb\n')
      local bufnr = open(dir .. '/u.txt')

      local st = attach_now(bufnr)
      ok(st.attached, 'the buffer is still attached')
      eq(signs.sign_count(bufnr), 0)
      eq(#attach.hunks(bufnr), 0)
    end),
  },
  {
    name = 'max_file_length refuses a long buffer',
    fn = guarded(function()
      config.setup({ max_file_length = 2 })
      local dir = helpers.git_repo('attach-toolong')
      helpers.write(dir .. '/big.txt', 'a\nb\nc\nd\ne\n')
      local bufnr = open(dir .. '/big.txt')

      eq(attach.attach(bufnr), nil)
      eq(attach.state(bufnr), nil)
    end),
  },
  {
    name = 'a nofile buffer is ignored',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-nofile')
      helpers.write(dir .. '/base.txt', 'base\n')
      local bufnr = open(dir .. '/base.txt')

      vim.bo[bufnr].buftype = 'nofile'
      eq(attach.attach(bufnr), nil)
      vim.bo[bufnr].buftype = ''
      eq(attach.count(), 0)
    end),
  },
  {
    name = 'an unnamed buffer is ignored',
    fn = guarded(function()
      local bufnr = api.nvim_create_buf(true, false)
      eq(attach.attach(bufnr), nil)
      api.nvim_buf_delete(bufnr, { force = true })
    end),
  },
  {
    name = 'a file that does not exist on disk is ignored',
    fn = guarded(function()
      local dir = helpers.scratch_dir('attach-missing')
      local bufnr = api.nvim_create_buf(true, false)
      api.nvim_buf_set_name(bufnr, dir .. '/nope.txt')

      eq(attach.attach(bufnr), nil)
      api.nvim_buf_delete(bufnr, { force = true })
    end),
  },
  {
    name = "config.signcolumn is applied to the buffer's window",
    fn = guarded(function()
      config.setup({ signcolumn = 'yes:2' })
      local dir = helpers.git_repo('attach-signcolumn')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr, win = open(dir .. '/base.txt')

      attach_now(bufnr)
      eq(vim.wo[win].signcolumn, 'yes:2')

      -- `false` means "do not touch the option".
      config.setup({ signcolumn = false })
      local dir2 = helpers.git_repo('attach-signcolumn-off')
      helpers.write(dir2 .. '/base.txt', 'base\nnew\n')
      local bufnr2, win2 = open(dir2 .. '/base.txt')
      vim.wo[win2].signcolumn = 'no'

      attach_now(bufnr2)
      eq(vim.wo[win2].signcolumn, 'no')
    end),
  },
  {
    name = 'a file outside any repository attaches nothing, and says nothing',
    fn = guarded(function()
      -- Deliberately *not* `scratch_dir`: that lives inside this plugin's own
      -- repository, so git root detection would legitimately find it.
      local file = vim.fn.tempname() .. '.txt'
      vim.fn.mkdir(vim.fs.dirname(file), 'p')
      vim.fn.writefile({ 'hello' }, file)

      local seen = helpers.capture_notify(function()
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        local bufnr = api.nvim_get_current_buf()
        attach.attach(bufnr)
        helpers.wait_for(function()
          local st = attach.state(bufnr)
          return st ~= nil and st.enabled == false
        end, 'the detection to come up empty')
      end)

      eq(attach.count(), 0)
      for _, msg in ipairs(seen) do
        ok(msg.level < vim.log.levels.WARN, 'unexpected notification: ' .. msg.message)
      end
      vim.fn.delete(file)
    end),
  },
  {
    name = 'detach clears the signs, the timer and the reference',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-detach')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      local timers = helpers.uv_count('timer')
      attach_now(bufnr)
      ok(signs.sign_count(bufnr) > 0, 'signs exist before detach')
      eq(manager.count(), 1)

      attach.detach(bufnr)
      eq(signs.sign_count(bufnr), 0)
      eq(signs.sign_count(bufnr, true), 0)
      helpers.wait_for(function()
        return manager.count() == 0
      end, 'the repository reference to be released')
      eq(helpers.uv_count('timer'), timers)
      eq(attach.state(bufnr), nil)
    end),
  },
  {
    name = 'attaching the same buffer twice is a no-op',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-idempotent')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      local first = attach_now(bufnr)
      eq(attach.count(), 1)

      -- The second attach must not run detection again.
      local probes = count_probes(function()
        local again = attach.attach(bufnr)
        ok(again == first, 'the second attach returns the same state')
      end)

      eq(probes, 0, 'no repository probe on the second attach')
      eq(attach.count(), 1)
    end),
  },
  {
    name = 'the accessors answer for an attached buffer',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-accessors')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      ok(attach.state(bufnr) == st)
      ok(attach.hunks(bufnr) == st.hunks)
      eq(attach.root(bufnr), dir)
      eq(attach.system(bufnr).name, 'git')
      eq(attach.capabilities(bufnr).staged_signs, true)
      eq(attach.count(), 1)
      eq(attach.buffers(), { bufnr }, 'the FocusGained sweep sees this buffer')
    end),
  },
  {
    name = 'toggle takes the signs off and brings them back, staying attached',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-toggle')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      attach_now(bufnr)
      ok(signs.sign_count(bufnr) > 0, 'signs start out drawn')

      eq(attach.toggle(bufnr), false, 'the switch now reads off')
      eq(signs.sign_count(bufnr), 0, 'the column is empty')
      eq(signs.sign_count(bufnr, true), 0)
      -- The switch is not a detach: the pipeline (and with it the repository
      -- reference) survives it, so turning it back on costs no detection.
      eq(attach.count(), 1)
      eq(attach.state(bufnr).attached, true)
      eq(manager.count(), 1)
      ok(#attach.hunks(bufnr) > 0, 'the accessors stay truthful while off')

      -- An edit while off must not schedule any work: `mark_dirty` returns before
      -- the debounce, so a spy on the debounced callable itself sees nothing — a
      -- stronger claim than "the hunks still look stale", and the wait is what
      -- makes it a claim about the 200ms debounce having been skipped.
      local toggle_state = attach.state(bufnr)
      local debounced = toggle_state.refresh
      local scheduled = 0
      toggle_state.refresh = function()
        scheduled = scheduled + 1
        return debounced()
      end
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'base', 'new', 'extra' })
      vim.wait(300, function()
        return false
      end)
      toggle_state.refresh = debounced
      eq(scheduled, 0, 'no refresh was scheduled while the switch was off')
      eq(attach.hunks(bufnr)[1].added.count, 1, 'the stale hunk was not recomputed')
      eq(signs.sign_count(bufnr), 0)

      eq(attach.toggle(bufnr), true)
      helpers.wait_for(function()
        return signs.sign_count(bufnr) > 0
      end, 'the signs to come back')
      eq(attach.hunks(bufnr)[1].added.count, 2, 'and they come from a fresh baseline')
    end),
  },
  {
    name = 'a staged change draws in the staged layer and leaves the worktree layer empty',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-staged')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      eq(#st.hunks, 0, 'nothing is left to stage')
      eq(#st.hunks_staged, 1, 'the index holds the change')
      eq(st.hunks_staged[1].added.start, 2)
      eq(signs.sign_count(bufnr), 0, 'the worktree layer is empty')
      eq(signs.sign_count(bufnr, true), 1)

      local staged = staged_rows(bufnr)[1]
      eq(staged.sign_hl_group, 'VcssignAddStaged')
      ok(staged.sign_hl_group ~= 'VcssignAdd', 'and it is not the worktree colour')
      eq(vim.trim(staged.sign_text or ''), '▎')
    end),
  },
  {
    name = 'a staged line that is edited again becomes an unstaged sign, not both',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-staged-edited')
      helpers.write(dir .. '/base.txt', 'base\none\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      helpers.write(dir .. '/base.txt', 'base\ntwo\n')
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      -- The unstaged layer is index -> buffer, so the line reads `change` there...
      eq(#st.hunks, 1)
      eq(st.hunks[1].type, 'change')
      eq(st.hunks[1].added.start, 2)
      -- ...and `filter_common` drops it from HEAD -> buffer, because the two
      -- layers would otherwise paint the same line twice (D40).
      eq(#st.hunks_staged, 0, 'the line is never in both layers')
      eq(signs.sign_count(bufnr), 1)
      eq(signs.sign_count(bufnr, true), 0)
      eq(rows(bufnr)[1].sign_hl_group, 'VcssignChange')
    end),
  },
  {
    name = 'a staged hunk and an unstaged hunk elsewhere keep to their own layers',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-staged-both')
      helpers.write(dir .. '/base.txt', 'a\nb\nc\n')
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'three lines', 'base.txt' })
      helpers.write(dir .. '/base.txt', 'A\nb\nC\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      -- Line 1 is edited again on top of the staged change; line 3 stays staged.
      helpers.write(dir .. '/base.txt', 'A2\nb\nC\n')
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      eq(#st.hunks, 1, 'only line 1 is left to stage')
      eq(st.hunks[1].added.start, 1)
      eq(#st.hunks_staged, 1, 'line 3 is still staged')
      eq(st.hunks_staged[1].added.start, 3)
      eq(st.hunks_staged[1].type, 'change')

      eq(signs.sign_count(bufnr), 1)
      eq(signs.sign_count(bufnr, true), 1)
      eq(rows(bufnr)[0].sign_hl_group, 'VcssignChange')
      eq(staged_rows(bufnr)[2].sign_hl_group, 'VcssignChangeStaged')
      eq(staged_rows(bufnr)[0], nil, 'line 1 is drawn by one layer only')
    end),
  },
  {
    name = 'svn has no staging area, so it only ever gets the worktree layer',
    fn = guarded(function()
      local dir = helpers.svn_checkout('attach-staged-svn')
      helpers.write(dir .. '/base.txt', 'mod\n')
      local bufnr = open(dir .. '/base.txt')

      local st = attach_now(bufnr)
      eq(st.system.name, 'svn')
      eq(st.system.capabilities.staged_signs, false)
      eq(#st.hunks, 1, 'the change itself is still drawn')
      eq(#st.hunks_staged, 0, 'no staged baseline was read at all')
      eq(signs.sign_count(bufnr, true), 0)
    end),
  },
  {
    name = 'toggle answers nil for a buffer with no file to diff',
    fn = guarded(function()
      local bufnr = api.nvim_create_buf(true, false)
      eq(attach.toggle(bufnr), nil)
      eq(attach.state(bufnr), nil)
      api.nvim_buf_delete(bufnr, { force = true })
    end),
  },
  {
    name = 'a repository that goes away lets the buffer go, and a later attach rebuilds it',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-abandoned')
      helpers.write(dir .. '/base.txt', 'changed\n')
      local bufnr = open(dir .. '/base.txt')
      attach_now(bufnr)
      ok(signs.sign_count(bufnr) > 0, 'the signs are up to begin with')

      -- What `rm -rf .git` ends in: the repository is disposed, every buffer
      -- holding it is deactivated (`repo:on_delete`).
      manager.get(dir):dispose()
      local st = attach.state(bufnr)
      eq(st.attached, false, 'the buffer lets go of the repository')
      eq(st.abandoned, true, 'and marks the state recoverable')
      eq(signs.sign_count(bufnr), 0, 'the signs go with it')
      eq(attach.count(), 0)

      -- The next `BufEnter` (or an explicit attach) must pick it up again:
      -- without the `abandoned` flag the dead state would be handed back and
      -- the buffer would stay sign-free forever.
      local again = attach.attach(bufnr)
      ok(again ~= st, 'a fresh state, not the dead one')
      helpers.wait_for(function()
        local now = attach.state(bufnr)
        return now ~= nil and now.attached and now.buf_text ~= nil
      end, 'the buffer to attach again')
      ok(signs.sign_count(bufnr) > 0, 'and the signs come back')
    end),
  },
  {
    name = 'a buffer that found no repository is picked up by an explicit refresh',
    fn = guarded(function()
      -- Deliberately *not* `scratch_dir`: that lives inside this plugin's own
      -- repository, so detection would legitimately find it.
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ 'base' }, dir .. '/base.txt')
      local bufnr = open(dir .. '/base.txt')
      local st = attach_now(bufnr)
      eq(st.enabled, false, 'there is no repository yet')
      eq(attach.count(), 0)

      -- `git init` behind the plugin's back.  `BufEnter` keeps the cached
      -- "no repository" answer on purpose (one detection per file outside a
      -- working copy is enough), so the way back is the explicit refresh.
      helpers.sh({ 'git', 'init', '-q', '-b', 'main' }, dir)
      helpers.sh({ 'git', 'add', 'base.txt' }, dir)
      helpers.sh({
        'git',
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '-qm',
        'init',
      }, dir)
      api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'changed' })
      attach.refresh(bufnr)
      helpers.wait_for(function()
        return signs.sign_count(bufnr) > 0
      end, 'the revived buffer to draw its signs')

      local now = attach.state(bufnr)
      ok(now ~= st, 'a fresh state, not the cached no-repository answer')
      eq(now.attached, true)
      eq(attach.count(), 1, 'and the repository is held again')
      vim.fn.delete(dir, 'rf')
    end),
  },
}
