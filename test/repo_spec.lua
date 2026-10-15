--- M2 acceptance: the repository runtime.
--- Covers impl/init/02-repo-runtime.md §5.1–5.5 plus the reference counting of
--- §4.
---
--- Every case builds its own throwaway repository: the shared `temp/` fixtures
--- have their exact status matrix asserted by the M1 specs, so staging a file
--- (or deleting a marker) in one of those would change the answer for the *next*
--- run of the suite.
local helpers = require('helpers')

local config = require('vcssign.config')
local exec = require('vcssign.exec')
local repo_manager = require('vcssign.repo_manager')

--- Count how many VCS status commands `fn` causes.
---
--- `repo.lua` reaches the adapters through module tables, so wrapping `exec.run`
--- here is seen by every command the plugin spawns — no test hook in
--- production code.
---@param fn fun()
---@return integer
local function count_status_runs(fn)
  local real_run = exec.run
  local calls = 0
  exec.run = function(cmd, opts, cb)
    if table.concat(cmd, ' '):find('status', 1, true) then
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

--- Run `fn` with a config override, restoring the previous options afterwards.
---@param opts table
---@param fn fun()
local function with_config(opts, fn)
  local saved = vim.deepcopy(config.get())
  config.setup(opts)
  local ok, err = pcall(fn)
  config.setup(saved)
  if not ok then
    error(err, 0)
  end
end

return {
  {
    name = 'the first refresh fills the cache',
    fn = function()
      local dir = helpers.git_repo('runtime-first')
      helpers.with_repo('spec:first', dir, function(repo)
        eq(repo.system.name, 'git')
        eq(repo.root, dir)
        eq(repo.has_loaded, true)
        eq(repo.is_dirty, false)
        eq(repo:entries(), {})
        eq(repo:get_status(dir .. '/base.txt'), nil)
        eq(repo:get_entry(dir .. '/base.txt'), nil)
      end)
    end,
  },
  {
    name = 'a worktree edit reaches the cache through the filesystem watcher',
    fn = function()
      local dir = helpers.git_repo('runtime-watch')
      helpers.with_repo('spec:watch', dir, function(repo)
        local updates = 0
        repo:on_update(function()
          updates = updates + 1
        end)

        local started = vim.uv.hrtime()
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.wait_for(function()
          return repo:get_status(dir .. '/base.txt') ~= nil
        end, 'the edit to be discovered by the watcher')
        -- §5.1's latency budget: debounce + one status command.
        local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
        ok(elapsed_ms <= 1000, string.format('discovery took %.0fms (budget 1000ms)', elapsed_ms))

        eq(helpers.status_set(repo:entries()), { 'base.txt:-/modified' })
        eq(updates, 1, 'one notification for one change')

        -- …and converge back once the edit is undone.
        helpers.write(dir .. '/base.txt', 'base\n')
        helpers.wait_for(function()
          return #repo:entries() == 0
        end, 'the status to converge back to clean')
        eq(updates, 2, 'the second change notifies again')
      end)
    end,
  },
  {
    name = 'an edit in a direct subdirectory is discovered too',
    fn = function()
      local dir = helpers.git_repo('runtime-subdir')
      helpers.with_repo('spec:subdir', dir, function(repo)
        helpers.write(dir .. '/sub/nested.txt', 'changed\n')
        helpers.wait_for(function()
          return helpers.entry(repo:entries(), 'sub/nested.txt') ~= nil
        end, 'the subdirectory edit (depth-1 watch)')
        eq(helpers.status_set(repo:entries()), { 'sub/nested.txt:-/modified' })
      end)
    end,
  },
  {
    name = 'ten rapid writes collapse into at most two status runs',
    fn = function()
      local dir = helpers.git_repo('runtime-coalesce')
      helpers.with_repo('spec:coalesce', dir, function(repo)
        local calls = count_status_runs(function()
          for i = 1, 10 do
            helpers.write(dir .. '/base.txt', 'v' .. i .. '\n')
          end
          helpers.wait_for(function()
            return repo:get_status(dir .. '/base.txt') ~= nil
          end, 'the burst to be discovered')
          -- Give a second round the chance to happen before asserting.
          vim.wait(600, function()
            return false
          end)
        end)
        ok(calls <= 2, 'expected the burst to coalesce, got ' .. calls .. ' status runs')
      end)
    end,
  },
  {
    name = 'refresh requests inside one window are served by a single run',
    fn = function()
      local dir = helpers.git_repo('runtime-waiters')
      helpers.with_repo('spec:waiters', dir, function(repo)
        helpers.write(dir .. '/base.txt', 'edited\n')

        local calls, seen = 0, nil
        repo:refresh(function(err, entries)
          calls = calls + 1
          eq(err, nil)
          seen = entries
        end)
        repo:refresh(function()
          calls = calls + 1
        end)
        helpers.wait_for(function()
          return calls == 2
        end, 'both refresh callbacks to be called')
        eq(helpers.status_set(seen), { 'base.txt:-/modified' }, 'the status reaches the callback')
      end)
    end,
  },
  {
    name = 'staging flips the index domain through the .git watch',
    fn = function()
      local dir = helpers.git_repo('runtime-stage')
      helpers.with_repo('spec:stage', dir, function(repo)
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.wait_for(function()
          return repo:get_status(dir .. '/base.txt') ~= nil
        end, 'the worktree edit')

        -- `git add` only rewrites `.git/index`; the worktree file does not
        -- change again, so this can only be seen through the metadata watch.
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        helpers.wait_for(function()
          local status = repo:get_status(dir .. '/base.txt')
          return status ~= nil and status.index == 'modified' and status.worktree == nil
        end, 'the index change to be picked up from .git')
      end)
    end,
  },
  {
    name = 'a vanished .git disposes the repository and frees every handle',
    fn = function()
      local dir = helpers.git_repo('runtime-marker-gone')
      local fs_baseline = helpers.uv_count('fs_event')
      local timer_baseline = helpers.uv_count('timer')
      local detached = 0
      local unsubscribe = repo_manager.on_repo_detached(function()
        detached = detached + 1
      end)

      local err, repo = helpers.wait(function(cb)
        repo_manager.attach('spec:marker-gone', dir, cb)
      end)
      eq(err, nil)
      ok(repo ~= nil, 'attach must succeed')
      ok(helpers.uv_count('fs_event') > fs_baseline, 'the watcher must hold handles')

      -- Renaming the metadata directory away is what a deleted worktree looks
      -- like from the outside, and it is what Windows allows while a handle is
      -- open on it.
      local renamed = vim.uv.fs_rename(dir .. '/.git', dir .. '/.git-gone')
      ok(renamed, 'the .git rename must succeed')
      helpers.wait_for(function()
        return repo_manager.get(dir) == nil
      end, 'the repository to be disposed once its marker disappeared')
      unsubscribe()

      eq(repo.is_deleted, true)
      eq(#vim.tbl_keys(repo.fs_handles), 0)
      eq(repo_manager.count(), 0)
      eq(repo_manager.ref_count(dir), 0)
      ok(detached >= 1, 'the detached event must fire')
      vim.wait(50, function()
        return false
      end)
      eq(helpers.uv_count('fs_event'), fs_baseline, 'no fs_event handle may leak')
      eq(helpers.uv_count('timer'), timer_baseline, 'no timer may leak')
    end,
  },
  {
    name = 'deleting an svn working copy cancels its watcher too',
    fn = function()
      local dir = helpers.svn_checkout('runtime-svn')
      local fs_baseline = helpers.uv_count('fs_event')
      helpers.with_repo('spec:svn', dir, function(repo)
        eq(repo.system.name, 'svn')
        -- A fresh checkout is pristine: this also pins that the initial refresh
        -- of a *clean* repository still populates the cache.
        eq(repo:entries(), {})

        -- One edit plus one new file, both picked up through the watcher.
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.write(dir .. '/zz-scratch.txt', 'x\n')
        helpers.wait_for(function()
          return #repo:entries() == 2
        end, 'the svn changes to be discovered')
        eq(helpers.status_set(repo:entries()), {
          'base.txt:-/modified',
          'zz-scratch.txt:-/untracked',
        }, 'svn has no index domain: everything lands in worktree')

        local renamed = vim.uv.fs_rename(dir .. '/.svn', dir .. '/.svn-gone')
        ok(renamed, 'the .svn rename must succeed')
        helpers.wait_for(function()
          return repo.is_deleted
        end, 'the svn repository to be disposed once .svn disappeared')
      end)
      vim.wait(50, function()
        return false
      end)
      eq(helpers.uv_count('fs_event'), fs_baseline, 'no fs_event handle may leak')
    end,
  },
  {
    name = 'a queued refresh callback is released when the repository goes away',
    fn = function()
      local dir = helpers.git_repo('runtime-waiter-gone')
      local err, repo = helpers.wait(function(cb)
        repo_manager.attach('spec:waiter-gone', dir, cb)
      end)
      eq(err, nil)

      local called, cb_err = false, nil
      -- Debounced, so the callback is still parked when the repo is released.
      repo:refresh(function(e)
        cb_err, called = e, true
      end)
      ok(#repo._waiters == 1, 'the callback must be queued')

      -- `detach` disposes synchronously; the marker-vanish path funnels through
      -- the same `_mark_deleted` but would have to wait for a filesystem event.
      repo_manager.detach('spec:waiter-gone')
      eq(called, true, 'the parked callback must be released, not dropped')
      ok(
        cb_err ~= nil and cb_err:find('deleted', 1, true) ~= nil,
        'the callback must be told why, got ' .. tostring(cb_err)
      )

      -- Requests made after disposal answer immediately instead of parking.
      local late_called, late_err = false, nil
      repo:refresh(function(e)
        late_err, late_called = e, true
      end)
      eq(late_called, true, 'a refresh on a disposed repo must not park the caller')
      ok(late_err ~= nil, 'it must report the reason')
      repo:refresh_now(function(e)
        late_err = e
      end)
      ok(late_err ~= nil, 'refresh_now must behave the same')
    end,
  },
  {
    name = 'a detach that races an in-flight attach does not leak a reference',
    fn = function()
      local dir = helpers.git_repo('runtime-attach-race')
      local fs_baseline = helpers.uv_count('fs_event')
      local called, cb_err = false, nil

      -- No `helpers.wait` here on purpose: detection is asynchronous and we
      -- release the reference while it is still running.
      repo_manager.attach('spec:race', dir, function(err)
        cb_err, called = err, true
      end)
      repo_manager.detach('spec:race')

      helpers.wait_for(function()
        return called
      end, 'the cancelled attach to report back')
      ok(
        cb_err ~= nil and cb_err:find('cancelled', 1, true) ~= nil,
        'expected a cancellation, got ' .. tostring(cb_err)
      )
      -- Give a stray late bind the chance to show up before asserting.
      vim.wait(200, function()
        return false
      end)
      eq(repo_manager.count(), 0, 'no repository may survive a released reference')
      eq(repo_manager.ref_count(dir), 0)
      eq(helpers.uv_count('fs_event'), fs_baseline, 'no watcher may be left behind')
    end,
  },
  {
    name = 'a status run that reports after dispose changes nothing',
    fn = function()
      -- A stub adapter, so the timing is fully controlled: the "command"
      -- reports back 30ms after a dispose that happens while it runs.
      local reported = false
      local system = {
        name = 'stub',
        keyfile = '.stub',
        capabilities = {},
        find_root_sync = function()
          return nil
        end,
        get_root_async = function(_, cb)
          cb(nil, nil)
        end,
        status = function(_, cb)
          vim.defer_fn(function()
            reported = true
            cb('stub: status exploded')
          end, 30)
        end,
      }
      local repo = require('vcssign.repo').new(system, helpers.plugin_root)
      local errors = 0
      repo:on_error(function()
        errors = errors + 1
      end)

      repo:refresh_now()
      ok(repo.is_updating, 'the run must be in flight')
      repo:dispose()

      helpers.wait_for(function()
        return reported
      end, 'the stubbed status to report back')
      vim.wait(50, function()
        return false
      end)
      eq(repo.is_updating, false, 'the in-flight flag must still be cleared')
      eq(repo.error_count, 0, 'a late failure must not touch the error state')
      eq(repo.last_error, nil)
      eq(errors, 0, 'on_error must not fire for a disposed repo')
      eq(repo._retry_timer, nil, 'and no retry timer may be armed')
    end,
  },
  {
    name = 'staging inside a linked worktree is picked up',
    fn = function()
      -- `.git` is a *file* here and the index lives in the main repository, so
      -- this only works if the metadata directory is resolved, not assumed.
      local worktree = helpers.git_worktree('runtime-worktree')
      helpers.with_repo('spec:worktree', worktree, function(repo)
        eq(repo.system.name, 'git')
        eq(repo:entries(), {})
        ok(
          repo.metadata_path ~= nil and repo.metadata_path ~= worktree .. '/.git',
          'the metadata directory must be the gitdir target, got ' .. tostring(repo.metadata_path)
        )
        eq(vim.uv.fs_stat(repo.metadata_path).type, 'directory')

        helpers.write(worktree .. '/base.txt', 'edited\n')
        helpers.wait_for(function()
          return repo:get_status(worktree .. '/base.txt') ~= nil
        end, 'the worktree edit')

        helpers.sh({ 'git', '-C', worktree, 'add', 'base.txt' })
        helpers.wait_for(function()
          local status = repo:get_status(worktree .. '/base.txt')
          return status ~= nil and status.index == 'modified' and status.worktree == nil
        end, 'the index change inside the worktree gitdir')
      end)
    end,
  },
  {
    name = 'references share one repo and the last release disposes it',
    fn = function()
      local dir = helpers.git_repo('runtime-refs')
      local fs_baseline = helpers.uv_count('fs_event')

      local err_a, repo_a = helpers.wait(function(cb)
        repo_manager.attach('spec:ref-a', dir, cb)
      end)
      eq(err_a, nil)
      eq(repo_manager.count(), 1)
      eq(repo_manager.ref_count(dir), 1)
      ok(helpers.uv_count('fs_event') > fs_baseline)

      local runs = count_status_runs(function()
        local err_b, repo_b = helpers.wait(function(cb)
          repo_manager.attach('spec:ref-b', dir .. '/base.txt', cb)
        end)
        eq(err_b, nil)
        ok(repo_b == repo_a, 'the second reference must reuse the same Repo object')
      end)
      eq(runs, 0, 'an in-sync cache is served without spawning a VCS command')
      eq(repo_manager.ref_count(dir), 2)

      repo_manager.detach('spec:ref-a')
      eq(repo_manager.count(), 1, 'the repository survives its first release')
      eq(repo_manager.ref_count(dir), 1)

      repo_manager.detach('spec:ref-b')
      eq(repo_manager.count(), 0)
      eq(repo_a.is_deleted, true)
      vim.wait(50, function()
        return false
      end)
      eq(helpers.uv_count('fs_event'), fs_baseline, 'no fs_event handle may leak')
    end,
  },
  {
    name = 'a failing status keeps the cache, warns once and backs off',
    fn = function()
      local dir = helpers.git_repo('runtime-fail')
      helpers.with_repo('spec:fail', dir, function(repo)
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.wait_for(function()
          return repo:get_status(dir .. '/base.txt') ~= nil
        end, 'the initial edit')
        local cached = helpers.status_set(repo:entries())

        local notifications = 0
        local real_notify = vim.notify
        vim.notify = function()
          notifications = notifications + 1
        end
        local errors = 0
        repo:on_error(function()
          errors = errors + 1
        end)

        -- Restore `vim.notify` whatever happens, otherwise every later case
        -- would log through the stub.
        local ok_body, body_err = pcall(function()
          with_config({ exec_timeout_ms = 1 }, function()
            repo:refresh_now()
            helpers.wait_for(function()
              return repo.error_count == 1
            end, 'the refresh to fail')

            -- The cache is untouched, the failure is remembered, a retry queued.
            eq(helpers.status_set(repo:entries()), cached, 'a failed run keeps the last good status')
            ok(repo.last_error ~= nil, 'the error must be remembered')
            ok(repo._retry_timer ~= nil, 'a backoff retry must be scheduled')
            eq(errors, 1, 'on_error must fire once per failed run')

            -- A second failure in the same streak warns once, not twice: the
            -- warning is deliberately per *streak*, and a manual refresh only
            -- restarts the backoff.
            repo:refresh_now()
            helpers.wait_for(function()
              return repo.error_count == 1
            end, 'the second failure')
            vim.wait(50, function()
              return false
            end)
            eq(errors, 2, 'every failed run reaches on_error')
            eq(notifications, 1, 'one warning per failure streak')
          end)
        end)
        vim.notify = real_notify
        if not ok_body then
          error(body_err, 0)
        end

        -- …and recovering clears the error state.  The callback is the only
        -- signal that the run finished, and it is called through a pcall (the
        -- pipeline isolates callbacks), so the result is recorded and asserted
        -- here rather than inside the callback.
        local done, recovery_err = false, nil
        repo:refresh_now(function(err)
          recovery_err, done = err, true
        end)
        helpers.wait_for(function()
          return done
        end, 'the recovery refresh to finish')
        eq(recovery_err, nil, 'the recovery refresh must succeed')
        eq(repo.error_count, 0)
        eq(repo.last_error, nil)
        eq(repo._retry_timer, nil)
        eq(helpers.status_set(repo:entries()), cached)
      end)
    end,
  },
  {
    name = 'the backoff retry recovers without any user input',
    fn = function()
      local dir = helpers.git_repo('runtime-retry')
      with_config({ retry_delay_ms = 100, retry_max_ms = 200 }, function()
        helpers.with_repo('spec:retry', dir, function(repo)
          with_config({ exec_timeout_ms = 1 }, function()
            repo:refresh_now()
            helpers.wait_for(function()
              return repo.error_count == 1
            end, 'the first failure')
            -- The retry fires on its own, fails again, and backs off further.
            helpers.wait_for(function()
              return repo.error_count >= 2
            end, 'the automatic retry to run')
          end)

          -- Commands work again: the next scheduled retry has to recover.
          helpers.wait_for(function()
            return repo.error_count == 0 and repo.last_error == nil
          end, 'the retry to succeed once commands work again')
          eq(helpers.status_set(repo:entries()), {})
        end)
      end)
    end,
  },
  {
    name = 'dispose_all leaves nothing behind',
    fn = function()
      local git_dir = helpers.git_repo('runtime-all-git')
      local svn_dir = helpers.svn_checkout('runtime-all-svn')
      local fs_baseline = helpers.uv_count('fs_event')
      local timer_baseline = helpers.uv_count('timer')

      helpers.wait(function(cb)
        repo_manager.attach('spec:all-git', git_dir, cb)
      end)
      helpers.wait(function(cb)
        repo_manager.attach('spec:all-svn', svn_dir, cb)
      end)
      eq(repo_manager.count(), 2)
      ok(helpers.uv_count('fs_event') > fs_baseline, 'two watchers must hold handles')

      repo_manager.dispose_all()
      eq(repo_manager.count(), 0)
      eq(repo_manager.ref_count(git_dir), 0)
      eq(repo_manager.ref_count(svn_dir), 0)
      vim.wait(50, function()
        return false
      end)
      eq(helpers.uv_count('fs_event'), fs_baseline)
      eq(helpers.uv_count('timer'), timer_baseline)
    end,
  },
  {
    name = 'path lookups are case-insensitive on Windows',
    fn = function()
      local dir = helpers.git_repo('runtime-case')
      -- Flip the drive letter: the same directory on Windows, a different string.
      local flipped = dir:sub(1, 1):lower() .. dir:sub(2)
      if flipped == dir then
        return -- POSIX: nothing to assert, paths really are case-sensitive
      end
      helpers.with_repo('spec:case', dir, function(repo)
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.wait_for(function()
          return repo:get_status(dir .. '/base.txt') ~= nil
        end, 'the edit')

        ok(repo_manager.get(flipped) == repo, 'get() must resolve the repository')
        eq(repo_manager.ref_count(flipped), 1)
        local status = repo:get_status(flipped .. '/base.txt')
        ok(status ~= nil, 'a case-flipped path must still find its entry')
        eq(status.worktree, 'modified')
      end)
    end,
  },
  {
    name = 'the repository root itself maps back to the repository',
    fn = function()
      -- Regression: the prefix comparison made the root one character too
      -- short to match itself, so `active()` in a session whose cwd *is* the
      -- repository root (`cd repo && nvim`) resolved nothing.
      local dir = helpers.git_repo('runtime-root-path')
      helpers.with_repo('spec:root', dir, function(repo)
        local vcs_base = require('vcssign.vcs.base')
        eq(vcs_base.relpath(dir, dir), '', 'the root is inside itself')
        eq(vcs_base.relpath(dir .. '/sub', dir), 'sub', 'sanity: a child still resolves')
        ok(repo_manager.get_by_path(dir) == repo, 'get_by_path must resolve the root')
        ok(repo_manager.get_by_path(dir .. '/base.txt') == repo, 'and a file in it')
      end)
    end,
  },
  {
    name = 'dispose_all cancels an attach that is still detecting',
    fn = function()
      -- Regression: `dispose_all` left the generation counter alone, so a
      -- detection still in flight would create a repository (with a watcher
      -- and a status command) *after* everything was disposed.
      local dir = helpers.git_repo('runtime-dispose-race')
      local baseline = helpers.uv_count('fs_event')
      local called, cb_err = false, nil

      -- Attach and dispose in the same tick: the detection callback cannot
      -- have run yet (it needs an event-loop turn), so this is deterministic.
      repo_manager.attach('spec:dispose-race', dir, function(err)
        cb_err, called = err, true
      end)
      repo_manager.dispose_all()

      helpers.wait_for(function()
        return called
      end, 'the cancelled attach to report back')
      ok(
        cb_err ~= nil and cb_err:find('cancelled', 1, true) ~= nil,
        'expected a cancellation, got ' .. tostring(cb_err)
      )
      vim.wait(200, function()
        return false
      end)
      eq(repo_manager.count(), 0, 'no repository may appear after dispose_all')
      eq(helpers.uv_count('fs_event'), baseline, 'no watcher may be left behind')
    end,
  },
  {
    name = 'a manual refresh inside the debounce window is not run twice',
    fn = function()
      -- Regression: `refresh_now` did not supersede an armed debounce, so a
      -- manual refresh landing inside the window was answered twice.
      local dir = helpers.git_repo('runtime-manual-coalesce')
      helpers.with_repo('spec:manual', dir, function(repo)
        with_config({ update_debounce_ms = 2000 }, function()
          -- Arm the debounce and let the event be delivered first, so the
          -- manual refresh below finds it armed (otherwise the test would
          -- depend on event-delivery timing).
          helpers.write(dir .. '/base.txt', 'edited\n')
          vim.wait(300, function()
            return false
          end)

          local runs = count_status_runs(function()
            repo:refresh_now()
            helpers.wait_for(function()
              return repo:get_status(dir .. '/base.txt') ~= nil
            end, 'the manual refresh')
            -- The (huge) debounce window closes here without a second run.
            vim.wait(2300, function()
              return false
            end)
          end)
          eq(runs, 1, 'the armed debounce must be superseded, got ' .. runs .. ' runs')
        end)
      end)
    end,
  },
  {
    name = 'active() resolves the repository of the current buffer',
    fn = function()
      local dir = helpers.git_repo('runtime-active')
      local err, repo = helpers.wait(function(cb)
        repo_manager.attach('spec:active', dir, cb)
      end)
      eq(err, nil)

      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/sub/nested.txt'))
      ok(repo_manager.active() == repo, 'the buffer inside the repo must resolve to it')
      vim.cmd('enew')
      eq(repo_manager.active(), nil, 'a scratch buffer belongs to no repository')
      repo_manager.detach('spec:active')
    end,
  },
}
