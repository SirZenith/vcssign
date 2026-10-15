--- Action specs: stage / unstage / commit / diff / open / refresh.
---
--- These are the cases where the plugin does something *irreversible* to a
--- repository, so every claim is checked against the VCS itself (`git diff
--- --cached`, `git log`, `svn log`) and not only against the plugin's own
--- cache — a cache that agrees with a command which did nothing is the failure
--- mode worth catching.
--- See impl/init/04-commands-actions.md §2, §6.
local actions = require('vcssign.actions')
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')
local helpers = require('helpers')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local sidebar = require('vcssign.sidebar')

--- Back to a clean editor between cases.
local function reset()
  sidebar.forget_all()
  manager.dispose_all()
  autocmds.disable()
  vim.cmd('silent! tabonly')
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('only')
  end
  -- Drop whatever buffer the previous case left behind (a diff view, say):
  -- "nothing was opened" is only meaningful from a known starting point.
  vim.cmd('silent! enew!')
end

--- Clean up whether the case passed or failed: a failing case would otherwise
--- leave a repository (and its watcher) behind for the next one.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    reset()
    if not ok then
      error(err, 0)
    end
  end
end

---@param ref string
---@param path string
---@return vcssign.Repo
local function attach_ready(ref, path)
  local err, repo = helpers.wait(function(cb)
    manager.attach(ref, path, cb)
  end)
  if not repo then
    error('attach failed: ' .. tostring(err), 2)
  end
  return repo
end

--- The status entry the VCS reported for `rel`, or nil.
---@param repo vcssign.Repo
---@param rel string
---@return vcssign.StatusEntry?
local function entry_of(repo, rel)
  return helpers.entry(repo:entries(), rel)
end

---@param repo vcssign.Repo
---@param rel string
---@return vcssign.StatusEntry
local function entry(repo, rel)
  local found = entry_of(repo, rel)
  if not found then
    error('no status entry for ' .. rel, 2)
  end
  return found
end

--- Wait until the cached status of `rel` reports `want` in `domain`.
---@param repo vcssign.Repo
---@param rel string
---@param domain "index"|"worktree"
---@param want vcssign.StatusType
local function wait_for_domain(repo, rel, domain, want)
  helpers.wait_for(function()
    local found = entry_of(repo, rel)
    return found ~= nil and found.status[domain] == want
  end, string.format('%s to report %s = %s', rel, domain, want))
end

--- Collect the notifications `fn` produces, waiting for them when the action
--- answers asynchronously (every VCS command does).
---
--- Not `helpers.capture_notify`, which only hands the list back once `fn`
--- returns: here the *case* has to wait for the answer, so the list must be
--- visible from inside `fn`.
---@param fn function
---@param is_done? fun(seen: vcssign.CapturedNotify[]): boolean  when given, the
---        case waits for a notification instead of assuming one already arrived
---@return vcssign.CapturedNotify[]
local function collect(fn, is_done)
  local real = vim.notify
  local seen = {} ---@type vcssign.CapturedNotify[]
  vim.notify = function(message, level)
    seen[#seen + 1] = { message = message, level = level or vim.log.levels.INFO }
  end
  local ok, err = pcall(fn)
  if ok then
    if is_done then
      if not vim.wait(5000, function()
        return is_done(seen)
      end, 10) then
        vim.notify = real
        error('timeout waiting for a notification', 2)
      end
    else
      vim.wait(50, function()
        return false
      end)
    end
  end
  vim.notify = real
  if not ok then
    error(err, 0)
  end
  return seen
end

--- Run `fn` with notifications swallowed.
---
--- The *setup* of a case (staging a file before testing a commit, say) produces
--- the same messages a user would see; the suite keeps stderr clean so that a
--- real warning stands out from the expected ones.
---@param fn function
local function quiet(fn)
  collect(fn)
end

--- How many diff views exist: the claim "pressing `d` twice reuses the buffer"
--- is about *those*, not about every buffer whose name mentions the file (an
--- earlier case may well have the file itself open).
---@return integer
local function diff_buffers()
  local n = 0
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'diff' then
      n = n + 1
    end
  end
  return n
end

--- Run `fn` with `vim.ui.input` answering `value` (nil = cancelled).
---@param value string?
---@param fn function
local function with_input(value, fn)
  local real = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm(value)
  end
  local ok, err = pcall(fn)
  vim.ui.input = real
  if not ok then
    error(err, 0)
  end
end

---@param opts table
---@param fn function
local function with_config(opts, fn)
  local saved = vim.deepcopy(config.get())
  config.setup(opts)
  local ok, err = pcall(fn)
  config.setup(saved)
  if not ok then
    error(err, 0)
  end
end

--- A git repo with one modified tracked file.
---@param name string
---@return vcssign.Repo, string dir
local function modified_repo(name)
  local dir = helpers.git_repo(name)
  helpers.write(dir .. '/base.txt', 'changed\n')
  local repo = attach_ready('spec:' .. name, dir)
  wait_for_domain(repo, 'base.txt', 'worktree', 'modified')
  return repo, dir
end

--- The window showing `bufnr`, or nil.
---@param bufnr integer
---@return integer?
local function win_of(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  return win == -1 and nil or win
end

--- Does `text` contain a line that is exactly `line`?
---
--- Lua patterns have no multiline flag, so `^foo$` matches only at the very
--- start and end of the whole diff — an assertion about a diff's *lines* that
--- quietly tests nothing.
---@param text string
---@param line string
---@return boolean
local function has_line(text, line)
  for _, candidate in ipairs(vim.split(text, '\n', { plain = true })) do
    if candidate == line then
      return true
    end
  end
  return false
end

--- Compare two paths regardless of how each side spells its separators.
---@param a string
---@param b string
---@return boolean
local function same_path(a, b)
  return vim.fs.normalize(a) == vim.fs.normalize(b)
end

---@param repo vcssign.Repo
---@return string
local function head(repo)
  return helpers.sh({ 'git', '-C', repo.root, 'rev-parse', 'HEAD' }):gsub('%s+$', '')
end

return {
  {
    name = 'stage moves a change into the index, and says so',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-stage')

      local seen = collect(function()
        actions.stage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'index', 'modified')
      end)
      eq(seen[1].message, 'vcssign: staged base.txt')
      eq(seen[1].level, vim.log.levels.INFO)
      -- The VCS agrees, and the worktree side is gone (staged *and* modified
      -- would mean the file was touched again after staging).
      eq(helpers.sh({ 'git', '-C', dir, 'diff', '--cached', '--name-only' }):gsub('%s+$', ''), 'base.txt')
      eq(entry_of(repo, 'base.txt').status.worktree, nil)
    end),
  },
  {
    name = 'unstage takes the change back out of the index',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-unstage')
      quiet(function()
        actions.stage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'index', 'modified')
      end)

      local seen = collect(function()
        actions.unstage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'worktree', 'modified')
      end)
      eq(seen[1].message, 'vcssign: unstaged base.txt')
      eq(helpers.sh({ 'git', '-C', dir, 'diff', '--cached', '--name-only' }), '')
    end),
  },
  {
    name = 'svn has no staging area, and is told so',
    fn = guarded(function()
      reset()
      local dir = helpers.svn_checkout('actions-svn-stage')
      helpers.write(dir .. '/base.txt', 'changed\n')
      local repo = attach_ready('spec:actions-svn-stage', dir)
      wait_for_domain(repo, 'base.txt', 'worktree', 'modified')

      local seen = collect(function()
        actions.stage(entry(repo, 'base.txt'))
        actions.unstage(entry(repo, 'base.txt'))
      end)
      -- System-scoped phrasing, no `vcssign:` prefix: the same sentence the
      -- sidebar's capability gate uses (03 §5).
      eq(seen[1].message, 'svn: no staging area')
      eq(seen[2].message, 'svn: no staging area')
      eq(seen[1].level, vim.log.levels.INFO, 'a missing capability is not an error')
      -- And nothing ran: the file is still just modified.
      eq(entry_of(repo, 'base.txt').status.worktree, 'modified')
    end),
  },
  {
    name = 'a failing stage reports what the VCS said',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-stage-fail')
      -- A held index lock is the one failure that is easy to produce on every
      -- platform and still says something diagnostic.
      helpers.write(dir .. '/.git/index.lock', '')
      local seen = collect(function()
        actions.stage(entry(repo, 'base.txt'))
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].level, vim.log.levels.ERROR)
      ok(seen[1].message:find('vcssign: ', 1, true) == 1, seen[1].message)
      ok(seen[1].message:lower():find('index.lock', 1, true), seen[1].message)
    end),
  },
  {
    name = 'commit commits a staged file after asking for a message',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-commit')
      quiet(function()
        actions.stage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'index', 'modified')
      end)

      local seen
      with_input('feat: change base', function()
        seen = collect(function()
          actions.commit(entry(repo, 'base.txt'))
        end, function(s)
          return #s > 0
        end)
      end)
      eq(helpers.sh({ 'git', '-C', dir, 'log', '-1', '--format=%s' }):gsub('%s+$', ''), 'feat: change base')
      ok(seen[1].message:find('committed base.txt', 1, true), seen[1].message)
      -- The index is clean again, so the sidebar's list empties out.
      helpers.wait_for(function()
        return #repo:entries() == 0
      end, 'the status to become clean')
    end),
  },
  {
    name = 'commit refuses a file that was never staged',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-commit-unstaged')
      local before = head(repo)

      local seen
      with_input('nope', function()
        seen = collect(function()
          actions.commit(entry(repo, 'base.txt'))
        end)
      end)
      ok(seen[1].message:find('not staged yet', 1, true), seen[1].message)
      eq(head(repo), before, 'nothing was committed')
    end),
  },
  {
    name = 'commit is dropped when the message prompt is cancelled or empty',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-commit-cancel')
      quiet(function()
        actions.stage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'index', 'modified')
      end)
      local before = head(repo)

      local cancelled
      with_input(nil, function()
        cancelled = collect(function()
          actions.commit(entry(repo, 'base.txt'))
        end)
      end)
      eq(#cancelled, 0, 'cancelling says nothing at all')

      local empty
      with_input('   ', function()
        empty = collect(function()
          actions.commit(entry(repo, 'base.txt'))
        end)
      end)
      ok(empty[1].message:find('empty commit message', 1, true), empty[1].message)
      eq(head(repo), before)
    end),
  },
  {
    name = 'svn commits the working copy without a staging step',
    fn = guarded(function()
      reset()
      local dir, url = helpers.svn_repo('actions-svn-commit')
      helpers.write(dir .. '/base.txt', 'committed from svn\n')
      local repo = attach_ready('spec:actions-svn-commit', dir)
      wait_for_domain(repo, 'base.txt', 'worktree', 'modified')

      local seen
      with_input('svn: edit base', function()
        seen = collect(function()
          actions.commit(entry(repo, 'base.txt'))
        end, function(s)
          return #s > 0
        end)
      end)
      -- Log the *URL*: `svn log` on a working copy stops at the BASE revision
      -- (still r1 here), so it would not show the commit that was just made.
      local log = helpers.sh({ 'svn', 'log', '-l', '1', '-v', url .. '/trunk' })
      ok(log:find('svn: edit base', 1, true), log)
      ok(log:find('r2', 1, true), 'a second revision exists:\n' .. log)
      -- The revision svn prints is part of the answer, not just "ok".
      ok(seen[1].message:find('committed base.txt', 1, true), seen[1].message)
      ok(seen[1].message:find('Committed revision', 1, true), seen[1].message)
      helpers.wait_for(function()
        return #repo:entries() == 0
      end, 'the working copy to become clean')
    end),
  },
  {
    name = 'diff shows a unified diff of the unstaged change',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-diff')

      local before = vim.api.nvim_get_current_win()
      local seen = collect(function()
        actions.diff(entry(repo, 'base.txt'))
        helpers.wait_for(function()
          return vim.api.nvim_get_current_win() ~= before
        end, 'the diff window')
      end)
      eq(#seen, 0, 'a diff is not a notification')

      local win = vim.api.nvim_get_current_win()
      local bufnr = vim.api.nvim_win_get_buf(win)
      eq(vim.bo[bufnr].filetype, 'diff', 'the built-in diff syntax should colour it')
      eq(vim.bo[bufnr].buftype, 'nofile')
      eq(vim.bo[bufnr].modifiable, false)
      local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      ok(has_line(text, '-base'), text)
      ok(has_line(text, '+changed'), text)
      -- Default mode is a vertical split on the right, half the screen wide.
      ok(vim.api.nvim_win_get_position(win)[2] > 0, 'the diff window is beside, not on top')
      eq(vim.api.nvim_win_get_width(win), math.max(40, math.floor(vim.o.columns / 2)))
      -- Pressing `d` again reuses the buffer *and* the window: a diff is a view
      -- of one file, and stacking copies of it helps nobody.
      local first = bufnr
      local windows = #vim.api.nvim_tabpage_list_wins(0)
      actions.diff(entry(repo, 'base.txt'))
      eq(vim.api.nvim_get_current_win(), win, 'focus came back to the same window')
      eq(#vim.api.nvim_tabpage_list_wins(0), windows, 'no second window')
      eq(diff_buffers(), 1)
      ok(vim.api.nvim_buf_is_valid(first), 'the first buffer is the one that survived')
    end),
  },
  {
    name = 'diff of a staged file compares against the index',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-diff-cached')
      local before = vim.api.nvim_get_current_win()
      quiet(function()
        actions.stage(entry(repo, 'base.txt'))
        wait_for_domain(repo, 'base.txt', 'index', 'modified')
      end)
      -- Touch the file again: it now has staged *and* worktree changes.  The
      -- row the user is on is the staged one, so the index is the side to
      -- compare against, and the newer edit must not appear.
      helpers.write(repo.root .. '/base.txt', 'changed again\n')
      repo:refresh_now()
      helpers.wait_for(function()
        local found = entry_of(repo, 'base.txt')
        return found ~= nil and found.status.index ~= nil and found.status.worktree ~= nil
      end, 'both domains to be set')

      actions.diff(entry(repo, 'base.txt'), { cached = true })
      helpers.wait_for(function()
        return vim.api.nvim_get_current_win() ~= before
      end, 'the diff window')
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), '\n')
      ok(has_line(text, '+changed'), 'the staged line is in the diff:\n' .. text)
      ok(not has_line(text, '+changed again'), 'the newer worktree edit is not:\n' .. text)
    end),
  },
  {
    name = 'diff.mode = "split" opens a horizontal window',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-diff-split')
      with_config({ diff = { mode = 'split' } }, function()
        local before = vim.api.nvim_get_current_win()
        actions.diff(entry(repo, 'base.txt'))
        helpers.wait_for(function()
          return vim.api.nvim_get_current_win() ~= before
        end, 'the diff window')
        local win = vim.api.nvim_get_current_win()
        eq(vim.api.nvim_win_get_height(win), math.max(10, math.floor(vim.o.lines / 2)))
        ok(vim.api.nvim_win_get_position(win)[1] > 0, 'below the window it came from')
        eq(vim.bo[vim.api.nvim_win_get_buf(win)].filetype, 'diff')
      end)
    end),
  },
  {
    name = 'diff says nothing to show rather than opening an empty buffer',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-diff-empty')
      -- A path target, so no status is involved: `git diff` on a clean file
      -- prints nothing at all.
      local windows = #vim.api.nvim_tabpage_list_wins(0)
      local seen = collect(function()
        actions.diff(repo.root .. '/sub/nested.txt')
      end, function(s)
        return #s > 0
      end)
      ok(seen[1].message:find('no changes to show', 1, true), seen[1].message)
      eq(#vim.api.nvim_tabpage_list_wins(0), windows, 'no window was opened')
    end),
  },
  {
    name = 'open refuses a file the VCS reports as deleted',
    fn = guarded(function()
      reset()
      local dir = helpers.git_repo('actions-open-deleted')
      vim.fn.delete(dir .. '/base.txt')
      local repo = attach_ready('spec:actions-open-deleted', dir)
      helpers.wait_for(function()
        local found = entry_of(repo, 'base.txt')
        return found ~= nil and found.status.worktree == 'deleted'
      end, 'the deletion to be reported')

      local seen = collect(function()
        actions.open(entry(repo, 'base.txt'))
      end)
      ok(seen[1].message:find('has been deleted', 1, true), seen[1].message)
      eq(vim.api.nvim_buf_get_name(0), '', 'nothing was opened in its place')
    end),
  },
  {
    name = 'open from the sidebar keeps the sidebar and uses another window',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-open')
      local win = sidebar.open(repo)
      local sidebar_buf = vim.api.nvim_win_get_buf(win)
      helpers.wait_for(function()
        for _, item in ipairs(renderer.items(sidebar_buf)) do
          if item.entry and item.entry.rel_path == 'base.txt' then
            return true
          end
        end
        return false
      end, 'the sidebar to list the file')
      vim.api.nvim_win_set_cursor(win, { 1, 0 })

      actions.open(entry(repo, 'base.txt'))
      ok(same_path(vim.api.nvim_buf_get_name(0), dir .. '/base.txt'), 'the file is in the current window')
      ok(win_of(sidebar_buf) ~= nil, 'and the sidebar is still on screen')
      ok(vim.api.nvim_get_current_win() ~= win, 'the sidebar window was not taken over')
    end),
  },
  {
    name = 'open with tab = true opens the file in a new tab',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-open-tab')
      actions.open(entry(repo, 'base.txt'), { tab = true })
      eq(#vim.api.nvim_list_tabpages(), 2)
      ok(same_path(vim.api.nvim_buf_get_name(0), dir .. '/base.txt'))
    end),
  },
  {
    name = 'open notices a file that vanished before the next status run',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-open-vanished')
      local target = entry(repo, 'base.txt')
      vim.fn.delete(dir .. '/base.txt')
      -- The cache still says "modified": the action has to look at the disk too.
      local seen = collect(function()
        actions.open(target)
      end)
      ok(seen[1].message:find('does not exist', 1, true), seen[1].message)
      eq(vim.api.nvim_buf_get_name(0), '')
      helpers.wait_for(function()
        local found = entry_of(repo, 'base.txt')
        return found ~= nil and found.status.worktree == 'deleted'
      end, 'the stale cache to be corrected in the background')
    end),
  },
  {
    name = 'refresh re-reads the repository without waiting for the debounce',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-refresh')
      helpers.write(dir .. '/new.txt', 'untracked\n')
      eq(entry_of(repo, 'new.txt'), nil, 'not in the cache yet')

      -- The *mechanism* is what is asserted: `refresh_now` starts the run
      -- immediately, so `is_updating` has already flipped when it returns, while
      -- the debounced path would leave the request waiting for its timer.  A
      -- wall clock would be flaky here — one `git status` can take longer than
      -- the debounce window, which is exactly what that window is for.
      actions.refresh(entry(repo, 'base.txt'))
      eq(repo.is_updating, true, 'the run starts without waiting for the debounce window')
      helpers.wait_for(function()
        return entry_of(repo, 'new.txt') ~= nil
      end, 'the new file to appear')
    end),
  },
  {
    name = 'refresh falls back to the only attached repository',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-refresh-only')
      -- No target to resolve: an unnamed buffer and a cwd outside any
      -- repository.  There is exactly one repository, so `:Vcssign refresh`
      -- means that one (04 §3).
      vim.cmd('enew')
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, 'p')
      vim.cmd('cd ' .. vim.fn.fnameescape(elsewhere))

      helpers.write(repo.root .. '/only.txt', 'untracked\n')
      actions.refresh()
      helpers.wait_for(function()
        return entry_of(repo, 'only.txt') ~= nil
      end, 'the only repository to be refreshed')
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'a path outside every repository is reported, not guessed at',
    fn = guarded(function()
      reset()
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      local seen = collect(function()
        actions.stage(dir .. '/whatever.txt')
      end)
      ok(seen[1].message:find('no repository', 1, true), seen[1].message)
      eq(seen[1].level, vim.log.levels.ERROR, 'the user asked for something impossible')
      vim.fn.delete(dir, 'rf')
    end),
  },
}
