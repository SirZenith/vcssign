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

--- Count how many subprocesses `fn` spawns.  No filtering, unlike
--- `count_probes`: this is the "costs nothing" assertion of the render
--- short-circuit (08 P0-4), where one stray `show` already fails it.
---@param fn fun()
---@return integer
local function count_procs(fn)
  local real_run = exec.run
  local calls = 0
  exec.run = function(cmd, opts, cb)
    calls = calls + 1
    return real_run(cmd, opts, cb)
  end
  local ok, err = pcall(fn)
  exec.run = real_run
  if not ok then
    error(err, 0)
  end
  return calls
end

--- Every command `fn` spawns, as `argv` strings, in order.
---
--- `count_procs` above answers "how many"; this answers "which ones", which is
--- what the status-cache cases need: the claim is not just that a clean file is
--- cheap, it is that no baseline was read for it.
---@param fn fun()
---@return string[]
local function spawned(fn)
  local real_run = exec.run
  local calls = {}
  exec.run = function(cmd, opts, cb)
    calls[#calls + 1] = table.concat(cmd, ' ')
    return real_run(cmd, opts, cb)
  end
  local ok, err = pcall(fn)
  exec.run = real_run
  if not ok then
    error(err, 0)
  end
  return calls
end

--- Start counting `attach._render` entries per buffer, until `stop()`.
---
--- *Entries*, not draws: the short-circuit (08 P0-4) returns from inside
--- `_render`, so an entry means "this buffer was told something moved" — which
--- is exactly what the changed-path channel (08 P0-3) decides.
---@return table<integer, integer> seen
---@return fun() stop
local function watch_renders()
  local real = attach._render
  local seen = {}
  attach._render = function(st, force)
    seen[st.bufnr] = (seen[st.bufnr] or 0) + 1
    return real(st, force)
  end
  return seen, function()
    attach._render = real
  end
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
    name = 'signcolumn = false draws no sign text and leaves the window option alone',
    fn = guarded(function()
      -- `signcolumn` is gitsigns': a boolean deciding whether `sign_text` is
      -- written at all.  vcssign never touches the window's `'signcolumn'` --
      -- writing that option from a `WinEnter` handler fires `OptionSet` even for
      -- the value the window already has, which is how `:Noice history` broke
      -- (07 §6.3).
      config.setup({ signcolumn = false })
      local dir = helpers.git_repo('attach-signcolumn-off')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr, win = open(dir .. '/base.txt')
      vim.wo[win].signcolumn = 'yes:2'

      attach_now(bufnr)
      eq(vim.wo[win].signcolumn, 'yes:2', "the window option stays the user's")
      eq(attach.hunks(bufnr)[1].added.count, 1, 'the hunks are still computed')
      eq(signs.sign_count(bufnr), 0, 'and nothing is drawn: no text, no highlight')
    end),
  },
  {
    name = 'numhl still gets its extmark when the sign text is off',
    fn = guarded(function()
      config.setup({ signcolumn = false, signs = { numhl = true } })
      local dir = helpers.git_repo('attach-signcolumn-numhl')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      attach_now(bufnr)

      local marks = api.nvim_buf_get_extmarks(bufnr, signs.namespace(false), 0, -1, {
        details = true,
      })
      eq(#marks, 1, 'one extmark')
      eq(marks[1][4].sign_text, nil, 'with no sign text')
      eq(marks[1][4].number_hl_group, 'VcssignAddNr', 'but the number highlight')
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
      -- Only what mentions *this* file: a repository an earlier case left behind
      -- can still be chatting, and this case is not about it (the same reason
      -- the other specs wait through `capture_notify_one`).
      local about = helpers.select_notifications(seen, vim.fs.basename(file))
      for _, msg in ipairs(about) do
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
      -- Wipe the buffer *before* the directory: a modified buffer whose file is
      -- gone makes Vim complain (`E211: File ... no longer available`) at the
      -- next buffer change, and the runner shows that on stderr.
      api.nvim_buf_delete(bufnr, { force = true })
      vim.fn.delete(dir, 'rf')
    end),
  },

  -- ▏ the render short-circuit (08 P0-4) ──────────────────────────────────────

  {
    name = 'an edit with no disk change spawns nothing to re-render',
    fn = guarded(function()
      -- The baseline is answered by a stat of the repository metadata, not by
      -- `show`, so a buffer with a modified line still needs no subprocess to
      -- redraw: the fingerprint (`changedtick` + baseline stamp) says only the
      -- buffer half moved.
      local dir = helpers.git_repo('attach-short-circuit-edit')
      helpers.write(dir .. '/base.txt', 'base\n')
      local bufnr = open(dir .. '/base.txt')
      attach_now(bufnr)
      eq(#attach.hunks(bufnr), 0, 'a clean file has no hunks')

      local procs = count_procs(function()
        api.nvim_buf_set_lines(bufnr, 1, 1, false, { 'added' })
        helpers.wait_for(function()
          return #attach.hunks(bufnr) == 1
        end, 'the debounced render to land')
      end)
      eq(procs, 0, 'the baseline did not move, so nothing may be spawned')
      eq(attach.hunks(bufnr)[1].added.start, 2)
      eq(signs.sign_count(bufnr), 1, 'and the sign is drawn')
    end),
  },

  {
    name = 'the focus sweep skips a baseline that did not move',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-short-circuit-sweep')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      attach_now(bufnr)
      eq(#attach.hunks(bufnr), 1)

      local procs = count_procs(function()
        attach.refresh_all()
      end)
      eq(procs, 0, 'FocusGained with nothing changed re-reads no baseline')
      eq(#attach.hunks(bufnr), 1, 'and the hunks we had are still the ones we have')
      eq(signs.sign_count(bufnr), 1)
    end),
  },

  {
    name = 'the focus sweep re-reads a baseline the index moved under',
    fn = guarded(function()
      -- The whole reason the sweep exists: another program stages the change.
      local dir = helpers.git_repo('attach-short-circuit-staged')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      local st = attach_now(bufnr)
      eq(#st.hunks, 1)
      eq(#st.hunks_staged, 0)

      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      local procs = count_procs(function()
        attach.refresh_all()
      end)
      ok(procs > 0, 'a moved index is re-read')
      helpers.wait_for(function()
        return #st.hunks == 0 and #st.hunks_staged == 1
      end, 'the staged layer to appear')
      eq(signs.sign_count(bufnr), 0, 'the worktree layer is empty')
      eq(signs.sign_count(bufnr, true), 1, 'and the staged one is not')
    end),
  },

  {
    name = 'the short-circuit still redraws when an option it read changes',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-short-circuit-config')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      attach_now(bufnr)
      eq(vim.trim(rows(bufnr)[1].sign_text or ''), '▎', 'the default sign text')

      -- `config.setup` replaces the table instead of mutating it, so the render
      -- fingerprint sees a different `signs`/`signcolumn`.  Without that half of
      -- the key, this would be the one way to freeze the signs for good.
      config.setup({ signcolumn = false, signs = { numhl = true } })
      attach.refresh_all()
      eq(rows(bufnr)[1].sign_text, nil, 'the sign text is gone')
      eq(rows(bufnr)[1].number_hl_group, 'VcssignAddNr', 'the number highlight is not')
    end),
  },

  -- ▏ the changed-path channel (08 P0-3) ─────────────────────────────────────

  {
    name = 'a work tree event enters only the buffer it names',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-changed-path')
      helpers.write(dir .. '/base.txt', 'base\n')
      local first = open(dir .. '/base.txt')
      attach_now(first)
      local second = open(dir .. '/sub/nested.txt')
      attach_now(second)
      eq(attach.count(), 2)

      -- Another program writes one of the two files.  The root watch is
      -- non-recursive, so libuv names the file, and the buffer that file
      -- belongs to is the only one with anything to do (08 P0-3).
      local renders, stop = watch_renders()
      local ran, err = pcall(function()
        helpers.write(dir .. '/base.txt', 'base\nreplaced on disk\n')
        helpers.wait_for(function()
          return (renders[first] or 0) > 0
        end, 'the event to reach the buffer')
        vim.wait(400, function()
          return false
        end)
      end)
      stop()
      if not ran then
        error(err, 0)
      end
      ok((renders[first] or 0) >= 1, 'the named buffer is entered')
      eq(renders[second], nil, 'the buffer the event did not name is left alone')
    end),
  },

  {
    name = 'a probe with nothing behind it enters no buffer at all',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-changed-path-none')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      local st = attach_now(bufnr)
      eq(#st.hunks, 1)

      local updates = 0
      st.repo:on_update(function()
        updates = updates + 1
      end)
      local renders, stop = watch_renders()
      local ran, err = pcall(function()
        -- This is `FocusGained` in one line: the liveness probe every focus
        -- gain runs.  It is the only thing that notices a repository that went
        -- away, so it stays — but with no filesystem event behind it there is
        -- nothing for any buffer to do (08 P0-3).
        st.repo:refresh()
        helpers.wait_for(function()
          return updates > 0
        end, 'the probe to announce')
        vim.wait(300, function()
          return false
        end)
      end)
      stop()
      if not ran then
        error(err, 0)
      end
      ok(updates >= 1, 'the probe still announces itself')
      eq(next(renders), nil, 'and no buffer is told to do anything')
      eq(#st.hunks, 1, 'the signs are what they were')
    end),
  },

  {
    name = 'a metadata change enters every buffer, because it names no path',
    fn = guarded(function()
      -- The other half of the rule: a staging change moves the baseline of the
      -- whole repository, so the announcement carries no path at all and every
      -- buffer re-reads.
      local dir = helpers.git_repo('attach-changed-path-index')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local first = open(dir .. '/base.txt')
      attach_now(first)
      helpers.write(dir .. '/sub/nested.txt', 'nested\nmore\n')
      local second = open(dir .. '/sub/nested.txt')
      attach_now(second)
      -- Let the work tree events of the two writes above drain first, so the
      -- window below can only see what `git add` causes.
      vim.wait(400, function()
        return false
      end)

      local renders, stop = watch_renders()
      local ran, err = pcall(function()
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        helpers.wait_for(function()
          return (renders[first] or 0) > 0 and (renders[second] or 0) > 0
        end, 'both buffers to be re-read')
      end)
      stop()
      if not ran then
        error(err, 0)
      end
    end),
  },
  {
    name = 'a clean file costs one status query and no baseline read',
    fn = guarded(function()
      -- The whole point of P0-1: nothing per file.  `rev-parse` is the
      -- detector's own root lookup, `status` is the repository-wide view, and
      -- the baseline is the buffer's own text because the view says the file is
      -- in sync with its index.
      local dir = helpers.git_repo('attach-status-clean')
      local bufnr = open(dir .. '/base.txt')
      local argv = spawned(function()
        attach_now(bufnr)
      end)
      eq(#argv, 2, 'two commands: ' .. table.concat(argv, ' | '))
      ok(argv[1]:find('rev%-parse'), 'first the root lookup: ' .. argv[1])
      ok(argv[2]:find('status', 1, true), 'then the status view: ' .. argv[2])
      local st = attach._bufs[bufnr]
      eq(#st.hunks, 0, 'a clean file has no hunks')
      eq(st.base_text, 'base', 'the baseline is the buffer text')
    end),
  },

  {
    name = 'an untracked file is answered by the view too, with no probe of its own',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-status-untracked')
      helpers.write(dir .. '/loose.txt', 'one\ntwo\n')
      local bufnr = open(dir .. '/loose.txt')
      local argv = spawned(function()
        attach_now(bufnr)
      end)
      eq(#argv, 2, 'two commands: ' .. table.concat(argv, ' | '))
      local st = attach._bufs[bufnr]
      eq(st.untracked, true)
      eq(st.base_text, '', 'an untracked baseline is the empty file')
      eq(#st.hunks, 1)
    end),
  },

  {
    name = 'a dirty file reads its baseline, and staging it reads HEAD as well',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-status-dirty')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')
      local argv = spawned(function()
        attach_now(bufnr)
      end)
      -- rev-parse + status + one `show :base.txt`; HEAD is not read because the
      -- view says the index matches it.
      eq(#argv, 3, 'three commands: ' .. table.concat(argv, ' | '))
      ok(argv[3]:find('show', 1, true), 'the baseline is read: ' .. argv[3])
      local st = attach._bufs[bufnr]
      eq(#st.hunks, 1)
      eq(#st.hunks_staged, 0)

      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      local staged_argv = spawned(function()
        refresh_now(bufnr)
      end)
      -- The index moved, so the cached view is retired: one status query plus
      -- the HEAD read the staged layer needs.  The baseline itself is the
      -- buffer's text now (worktree in sync), so no second `show`.
      eq(#staged_argv, 2, 'two commands: ' .. table.concat(staged_argv, ' | '))
      ok(staged_argv[2]:find('show HEAD', 1, true), 'HEAD is read: ' .. staged_argv[2])
      eq(#st.hunks, 0, 'the worktree layer is empty again')
      eq(#st.hunks_staged, 1, 'and the staged layer has the hunk')
    end),
  },

  {
    name = 'a status query that fails falls back to the per-file questions',
    fn = guarded(function()
      local dir = helpers.git_repo('attach-status-failure')
      helpers.write(dir .. '/base.txt', 'base\nnew\n')
      local bufnr = open(dir .. '/base.txt')

      -- The view is optional: an adapter, or a working copy, that cannot answer
      -- it must lose the shortcut, not the signs.
      local system = require('vcssign.vcs.git')
      local real_status, real_tracked = system.status, system.is_tracked
      local asked = 0
      system.status = function(_, cb)
        cb('boom')
      end
      system.is_tracked = function(...)
        asked = asked + 1
        return real_tracked(...)
      end
      local ok_attach, attach_err = pcall(attach_now, bufnr)
      system.status, system.is_tracked = real_status, real_tracked
      if not ok_attach then
        error(attach_err, 0)
      end
      eq(asked, 1, 'the per-file question is asked instead')
      eq(#attach.hunks(bufnr), 1, 'and the signs are still right')
    end),
  },
}
