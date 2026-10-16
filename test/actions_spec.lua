--- Action specs: stage / unstage / commit / diff / refresh.
---
--- These are the cases where the plugin does something *irreversible* to a
--- repository, so every claim is checked against the VCS itself (`git diff
--- --cached`, `git log`, `svn log`) and not only against the plugin's own
--- cache — a cache that agrees with a command which did nothing is the failure
--- mode worth catching.
---
--- `Repo` stopped caching status in M6 (D38), so "the plugin saw the change"
--- is asserted through the VCS (the helpers below) or through the refresh
--- mechanism (`helpers.count_refreshes`), never through a status list.
--- See impl/init/04-commands-actions.md §2, §6.
local actions = require('vcssign.actions')
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')
local helpers = require('helpers')
local manager = require('vcssign.repo_manager')

--- Back to a clean editor between cases.
local function reset()
  manager.dispose_all()
  autocmds.disable()
  vim.cmd('silent! tabonly')
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('only')
  end
  -- Drop whatever buffer the previous case left behind (a diff view, say):
  -- "nothing was opened" is only meaningful from a known starting point.  The
  -- cwd matters too: one case moves it, and relative paths everywhere else
  -- would quietly mean something else.
  vim.cmd('silent! enew!')
  vim.cmd('cd ' .. vim.fn.fnameescape(helpers.plugin_root))
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

--- The absolute path a target needs: actions are path-based in M6.
---@param repo vcssign.Repo
---@param rel string
---@return string
local function file(repo, rel)
  return repo.root .. '/' .. rel
end

--- What `git diff <args>` reports, one path per line (`''` when clean).
---
--- `--name-only` reduces the answer to "which files differ", which is all these
--- cases need; the string is trimmed because even a shell-free `vim.system`
--- hands back a trailing newline.
---@param dir string
---@param args? string[]
---@return string
local function git_diff(dir, args)
  local cmd = { 'git', '-C', dir, 'diff' }
  vim.list_extend(cmd, args or {})
  cmd[#cmd + 1] = '--name-only'
  return (helpers.sh(cmd):gsub('%s+$', ''))
end

--- svn's status line for one path (`''` when clean).  The first column is the
--- documented thing this suite reads, exactly as a user would read it.
---@param path string
---@return string
local function svn_status(path)
  return (helpers.sh({ 'svn', 'status', '--', path }):gsub('%s+$', ''))
end

-- `helpers.capture_notify` with the optional wait predicate: the VCS answers
-- asynchronously, so a case has to wait for its notification while the stub
-- is still in place.
local collect = helpers.capture_notify

--- Stage `rel` and wait for the plugin to say so.
---
--- The answer is only emitted once the VCS command has succeeded, so it doubles
--- as the rendezvous: no case has to sleep on a wall clock to know that the
--- index really changed.
---@param dir string
---@param rel string
---@return vcssign.CapturedNotify[]
local function stage_quietly(dir, rel)
  return collect(function()
    actions.stage(dir .. '/' .. rel)
  end, function(s)
    return #s > 0
  end)
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
---
--- `fn` gets a getter for how many times the prompt was actually shown, so a
--- case can wait for the VCS round trips in front of the prompt instead of
--- hoping that a fixed drain window covered them.
---@param value string?
---@param fn fun(asked: fun(): integer)
local function with_input(value, fn)
  local real = vim.ui.input
  local asked = 0
  vim.ui.input = function(_, on_confirm)
    asked = asked + 1
    on_confirm(value)
  end
  local ok, err = pcall(fn, function()
    return asked
  end)
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
  -- The fixture is only useful if it really is modified, and this is the
  -- strongest available way to say so.
  eq(git_diff(dir), 'base.txt', 'the fixture starts with one worktree change')
  local repo = attach_ready('spec:' .. name, dir)
  return repo, dir
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
      local _, dir = modified_repo('actions-stage')

      local seen = stage_quietly(dir, 'base.txt')
      eq(seen[1].message, 'vcssign: staged base.txt')
      eq(seen[1].level, vim.log.levels.INFO)
      -- The VCS agrees, and the worktree side is gone (staged *and* modified
      -- would mean the file was touched again after staging).
      eq(git_diff(dir, { '--cached' }), 'base.txt')
      eq(git_diff(dir), '', 'the worktree matches the index again')
    end),
  },
  {
    name = 'unstage takes the change back out of the index',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-unstage')
      stage_quietly(dir, 'base.txt')

      local seen = collect(function()
        actions.unstage(file(repo, 'base.txt'))
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].message, 'vcssign: unstaged base.txt')
      eq(git_diff(dir, { '--cached' }), '')
      eq(git_diff(dir), 'base.txt', 'the change is back in the worktree')
    end),
  },
  {
    name = 'svn has no staging area, and is told so',
    fn = guarded(function()
      reset()
      local dir = helpers.svn_checkout('actions-svn-stage')
      helpers.write(dir .. '/base.txt', 'changed\n')
      local repo = attach_ready('spec:actions-svn-stage', dir)
      eq(svn_status(file(repo, 'base.txt')):sub(1, 1), 'M', 'the fixture starts modified')

      local seen = collect(function()
        actions.stage(file(repo, 'base.txt'))
        actions.unstage(file(repo, 'base.txt'))
      end)
      -- System-scoped phrasing, no `vcssign:` prefix: the same sentence the
      -- capability gate uses.
      eq(seen[1].message, 'svn: no staging area')
      eq(seen[2].message, 'svn: no staging area')
      eq(seen[1].level, vim.log.levels.INFO, 'a missing capability is not an error')
      -- And nothing ran: the file is still just modified.
      eq(svn_status(file(repo, 'base.txt')):sub(1, 1), 'M')
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
        actions.stage(file(repo, 'base.txt'))
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
      stage_quietly(dir, 'base.txt')

      local seen
      with_input('feat: change base', function()
        seen = collect(function()
          actions.commit(file(repo, 'base.txt'))
        end, function(s)
          return #s > 0
        end)
      end)
      eq(
        helpers.sh({ 'git', '-C', dir, 'log', '-1', '--format=%s' }):gsub('%s+$', ''),
        'feat: change base'
      )
      ok(seen[1].message:find('committed base.txt', 1, true), seen[1].message)
      -- Nothing is left over: the index matches the new HEAD, and so does the
      -- worktree.
      eq(git_diff(dir, { '--cached' }), '', 'the index is clean again')
      eq(git_diff(dir), '', 'and so is the worktree')
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
          actions.commit(file(repo, 'base.txt'))
        end, function(s)
          return #s > 0
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
      local repo, dir = modified_repo('actions-commit-cancel')
      stage_quietly(dir, 'base.txt')
      local before = head(repo)

      -- Cancelling reaches the prompt last, after the baseline reads in front
      -- of it; the getter says when that happened without guessing at a
      -- duration.
      local cancelled
      with_input(nil, function(asked)
        cancelled = collect(function()
          actions.commit(file(repo, 'base.txt'))
          helpers.wait_for(function()
            return asked() > 0
          end, 'the commit prompt')
        end)
      end)
      eq(#cancelled, 0, 'cancelling says nothing at all')

      local empty
      with_input('   ', function(asked)
        empty = collect(function()
          actions.commit(file(repo, 'base.txt'))
          helpers.wait_for(function()
            return asked() > 0
          end, 'the commit prompt')
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
      eq(svn_status(file(repo, 'base.txt')):sub(1, 1), 'M', 'the fixture starts modified')

      local seen
      with_input('svn: edit base', function()
        seen = collect(function()
          actions.commit(file(repo, 'base.txt'))
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
      eq(svn_status(file(repo, 'base.txt')), '', 'and the working copy is clean')
    end),
  },
  {
    name = 'diff shows a unified diff of the worktree change',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-diff')

      local before = vim.api.nvim_get_current_win()
      local seen = collect(function()
        -- The default baseline is the index (`config.rev`), which holds nothing
        -- here; the worktree side is the one to ask for explicitly.
        actions.diff(file(repo, 'base.txt'), { cached = false })
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
      actions.diff(file(repo, 'base.txt'), { cached = false })
      eq(vim.api.nvim_get_current_win(), win, 'focus came back to the same window')
      eq(#vim.api.nvim_tabpage_list_wins(0), windows, 'no second window')
      eq(diff_buffers(), 1)
      ok(vim.api.nvim_buf_is_valid(first), 'the first buffer is the one that survived')
    end),
  },
  {
    name = 'diff uses the configured baseline: the index by default',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-diff-cached')
      local before = vim.api.nvim_get_current_win()
      stage_quietly(dir, 'base.txt')
      -- Touch the file again: it now has staged *and* worktree changes.  With
      -- no `opts` the diff follows `config.rev`, which is 'index' by default,
      -- so the newer edit must not appear.
      helpers.write(repo.root .. '/base.txt', 'changed again\n')

      actions.diff(file(repo, 'base.txt'))
      helpers.wait_for(function()
        return vim.api.nvim_get_current_win() ~= before
      end, 'the diff window')
      local text =
        table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false), '\n')
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
        actions.diff(file(repo, 'base.txt'), { cached = false })
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
      -- A path target, so nothing but the adapter is involved: the file is
      -- clean, and a diff against the index prints nothing at all.
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
    name = 'refresh re-reads the repository without waiting for the debounce',
    fn = guarded(function()
      reset()
      local repo = modified_repo('actions-refresh')

      -- The *mechanism* is what is asserted: `refresh_now` starts the probe
      -- immediately, so `is_updating` has already flipped when it returns, while
      -- the debounced path would leave the request waiting for its timer.  A
      -- wall clock would be flaky here — one probe can take longer than
      -- the debounce window, which is exactly what that window is for.
      local passes = helpers.count_refreshes(repo)
      actions.refresh(file(repo, 'base.txt'))
      eq(repo.is_updating, true, 'the run starts without waiting for the debounce window')
      helpers.wait_for(function()
        return passes() > 0
      end, 'the refresh to land')
      helpers.wait_for(function()
        return not repo.is_updating
      end, 'the refresh to finish')
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

      local passes = helpers.count_refreshes(repo)
      actions.refresh()
      helpers.wait_for(function()
        return passes() > 0
      end, 'the only repository to be refreshed')
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'a path is acted on in the deepest repository containing it',
    fn = guarded(function()
      reset()
      -- A repository inside a repository (submodule, vendored checkout, or
      -- simply a test repository — which is how this was found).  Both are
      -- attached, and a path inside the inner one belongs to the inner one:
      -- resolving it against the outer repository would name a file that does
      -- not exist there.
      local outer = helpers.git_repo('actions-nested-outer')
      local inner = helpers.git_repo('actions-nested-outer/inner')
      local outer_repo = attach_ready('spec:actions-outer', outer)
      local inner_repo = attach_ready('spec:actions-inner', inner .. '/base.txt')

      local outer_passes = helpers.count_refreshes(outer_repo)
      local inner_passes = helpers.count_refreshes(inner_repo)
      actions.refresh(inner .. '/base.txt')
      helpers.wait_for(function()
        return inner_passes() > 0
      end, 'the nested repository to be refreshed')
      eq(outer_passes(), 0, 'the outer repository was left alone')
    end),
  },
  {
    name = 'a diff the VCS refuses is reported, not swallowed',
    fn = guarded(function()
      reset()
      local dir = helpers.svn_repo('actions-diff-error')
      -- An unversioned file: svn lists it as `?`, and `svn diff` on it fails.
      helpers.write(dir .. '/loose.txt', 'loose\n')
      local repo = attach_ready('spec:actions-diff-error', dir)
      eq(svn_status(file(repo, 'loose.txt')):sub(1, 1), '?', 'the fixture is unversioned')

      local windows = #vim.api.nvim_tabpage_list_wins(0)
      local seen = collect(function()
        actions.diff(file(repo, 'loose.txt'))
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].level, vim.log.levels.ERROR)
      ok(seen[1].message:find('vcssign: ', 1, true) == 1, seen[1].message)
      eq(#vim.api.nvim_tabpage_list_wins(0), windows, 'and no empty diff window was left behind')
    end),
  },
  {
    name = 'commit refuses a directory row instead of committing a whole subtree',
    fn = guarded(function()
      reset()
      -- svn lists directories as entries, and `svn commit -- <dir>` commits
      -- everything under it — more than the row the user pointed at.
      local dir = helpers.svn_repo('actions-commit-dir')
      -- A directory that is itself scheduled for addition is what makes svn
      -- list a directory row (adding a *file* with `--parents` schedules only
      -- the file, measured).
      helpers.sh({ 'svn', 'mkdir', '--parents', '-q', dir .. '/newdir' })
      local repo = attach_ready('spec:actions-commit-dir', dir)
      eq(svn_status(file(repo, 'newdir')):sub(1, 1), 'A', 'svn schedules the new directory')

      local seen
      with_input('should not happen', function()
        seen = collect(function()
          actions.commit(file(repo, 'newdir'))
        end)
      end)
      ok(seen[1].message:find('is not a file', 1, true), seen[1].message)
      -- Nothing was committed.
      ok(helpers.sh({ 'svn', 'log', '-l', '1', dir }):find('r1', 1, true), 'still at r1')
    end),
  },
  {
    name = 'a commit that is asked to use the buffer prompt says so and falls back',
    fn = guarded(function()
      reset()
      local repo, dir = modified_repo('actions-commit-buffer-input')
      stage_quietly(dir, 'base.txt')
      with_config({ commit = { message_input = 'buffer' } }, function()
        local seen
        with_input('fallback still works', function()
          -- Wait for the *commit* answer, not for the first notification: the
          -- unimplemented-mode warning arrives before it.
          seen = collect(function()
            actions.commit(file(repo, 'base.txt'))
          end, function(s)
            for _, notification in ipairs(s) do
              if notification.message:find('committed', 1, true) then
                return true
              end
            end
            return false
          end)
        end)
        -- The warning about the unimplemented mode, then the normal answer.
        ok(seen[1].message:find('not implemented', 1, true), seen[1].message)
        eq(seen[1].level, vim.log.levels.WARN)
        eq(
          helpers.sh({ 'git', '-C', dir, 'log', '-1', '--format=%s' }):gsub('%s+$', ''),
          'fallback still works'
        )
      end)
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
