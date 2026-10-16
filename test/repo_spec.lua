--- M6 Step 2 acceptance: the repository runtime as a *metadata session*.
---
--- `Repo` no longer caches a status view (D38): it watches one metadata
--- directory, probes that the repository still exists, and broadcasts the
--- answer.  The four things worth pinning are therefore:
---
---   1. one metadata event reaches subscribers exactly once;
---   2. an event storm (or several requests) collapses into one probe;
---   3. a failed probe backs off, and a definitive "not a repository" deletes;
---   4. nothing (fs_event handle, timer, waiter, reference) outlives `dispose`.
---
--- Every case builds its own throwaway repository: the shared `temp/` fixtures
--- have their exact status matrix asserted by the M1 specs, so staging a file
--- (or deleting a marker) in one of those would change the answer for the *next*
--- run of the suite.
local helpers = require('helpers')

local config = require('vcssign.config')
local exec = require('vcssign.exec')
local repo_manager = require('vcssign.repo_manager')

--- Count how many *liveness probes* `fn` causes.
---
--- `repo.lua` reaches the adapters through module tables, so wrapping `exec.run`
--- here is seen by every command the plugin spawns — no test hook in
--- production code.  The probe is `git rev-parse --show-toplevel` (or
--- `svn info --show-item wc-root`), so nothing else counts.
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

--- Clean up whether the case passed or failed: a failing case would otherwise
--- leave a repository (and its watcher) behind for the next one.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    repo_manager.dispose_all()
    if not ok then
      error(err, 0)
    end
  end
end

return {
  {
    name = 'the first probe marks the repository loaded, with no status cache',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-first')
      helpers.with_repo('spec:first', dir, function(repo)
        eq(repo.system.name, 'git')
        eq(repo.root, dir)
        ok(repo.has_loaded, 'has_loaded must be set by the first successful probe')
        eq(repo.is_dirty, false)
        eq(repo.error_count, 0)
        -- No `entries()`/`get_status()` any more (D38); the metadata watch is
        -- the only handle it keeps.
        ok(
          repo.watch_paths[vim.fs.normalize(repo.metadata_path)],
          'the metadata directory must be watched'
        )
      end)
    end),
  },
  {
    name = 'a metadata change is announced exactly once',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-meta')
      helpers.with_repo('spec:meta', dir, function(repo)
        local updates = 0
        repo:on_update(function()
          updates = updates + 1
        end)
        -- Let the initial announcement (if any) land before counting.
        vim.wait(250, function()
          return false
        end)
        local baseline = updates

        -- `git add` rewrites `.git/index`; the worktree is not watched any
        -- more, so this is the only route by which the change can be seen.
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        helpers.wait_for(function()
          return updates > baseline
        end, 'the metadata event')
        vim.wait(400, function()
          return false
        end)
        eq(updates - baseline, 1, 'one metadata change must be announced once')
      end)
    end),
  },
  {
    name = 'a burst of changes collapses into a single probe',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-coalesce')
      helpers.with_repo('spec:coalesce', dir, function(repo)
        vim.wait(300, function()
          return false
        end)
        local probes = count_probes(function()
          for _ = 1, 10 do
            repo:mark_dirty()
          end
          helpers.wait_for(function()
            return not repo.is_dirty
          end, 'the burst to be probed')
          -- Give a second round the chance to happen before asserting.
          vim.wait(600, function()
            return false
          end)
        end)
        eq(probes, 1, 'expected the burst to coalesce, got ' .. probes .. ' probes')
      end)
    end),
  },
  {
    name = 'refresh requests inside one window share a single probe',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-waiters')
      helpers.with_repo('spec:waiters', dir, function(repo)
        vim.wait(300, function()
          return false
        end)
        local a_called, b_called = 0, 0
        local a_err, b_err = 'unset', 'unset'
        local probes = count_probes(function()
          repo:refresh(function(err)
            a_err, a_called = err, a_called + 1
          end)
          repo:refresh(function(err)
            b_err, b_called = err, b_called + 1
          end)
          helpers.wait_for(function()
            return a_called == 1 and b_called == 1
          end, 'both refresh callbacks to be called')
        end)
        eq(a_err, nil, 'a successful probe answers nil')
        eq(b_err, nil, 'the second waiter shares the same answer')
        eq(probes, 1, 'two requests in one window must share one probe')
      end)
    end),
  },
  {
    name = 'a manual refresh inside the debounce window is not run twice',
    fn = guarded(function()
      -- Regression: `refresh_now` did not supersede an armed debounce, so a
      -- manual refresh landing inside the window was answered twice.
      local dir = helpers.git_repo('runtime-manual-coalesce')
      helpers.with_repo('spec:manual', dir, function(repo)
        eq(repo.has_loaded, true)
        with_config({ update_debounce_ms = 2000 }, function()
          -- Arm the debounce first, so the manual refresh below finds it armed.
          repo:mark_dirty()
          vim.wait(300, function()
            return false
          end)

          local probes = count_probes(function()
            repo:refresh_now()
            helpers.wait_for(function()
              return not repo.is_updating
            end, 'the manual probe')
            -- The (huge) debounce window closes here without a second probe.
            vim.wait(2300, function()
              return false
            end)
          end)
          eq(probes, 1, 'the armed debounce must be superseded, got ' .. probes .. ' probes')
        end)
      end)
    end),
  },
  {
    name = 'a failing probe warns once, backs off, and the retry recovers',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-retry')
      helpers.with_repo('spec:retry', dir, function(repo)
        helpers.wait_for(function()
          return repo.has_loaded
        end, 'the first probe')

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
            end, 'the probe to fail')

            -- The repository was alive a moment ago, so a failed probe does not
            -- unload it; the failure is remembered and a retry queued.
            eq(repo.has_loaded, true, 'a failed probe must not unload a live repository')
            ok(repo.last_error ~= nil, 'the error must be remembered')
            ok(repo._retry_timer ~= nil, 'a backoff retry must be scheduled')
            eq(errors, 1, 'on_error must fire once per failed run')
            eq(notifications, 1, 'one warning per failure streak')

            -- A second failure in the same streak warns once, not twice.
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

        -- Commands work again: the scheduled retry has to recover on its own,
        -- without any user input.
        helpers.wait_for(function()
          return repo.error_count == 0 and repo.last_error == nil
        end, 'the retry to succeed once commands work again')
        eq(repo._retry_timer, nil)
      end)
    end),
  },
  {
    name = 'the backoff retry recovers without any user input',
    fn = guarded(function()
      -- Deliberately does *not* stub `vim.notify`: this is the case whose one
      -- expected warning is the suite's single stderr line (see
      -- impl/init/05-testing-infra.md §6).  The probe now runs `git rev-parse`,
      -- so that line names `rev-parse --show-toplevel`.
      local dir = helpers.git_repo('runtime-retry-real')
      with_config({ retry_delay_ms = 100, retry_max_ms = 200 }, function()
        helpers.with_repo('spec:retry-real', dir, function(repo)
          with_config({ exec_timeout_ms = 1 }, function()
            repo:refresh_now()
            helpers.wait_for(function()
              return repo.error_count == 1
            end, 'the first failure')
            -- The retry fires on its own, fails again, and backs off further.
            -- Only the first failure of the streak warns.
            helpers.wait_for(function()
              return repo.error_count >= 2
            end, 'the automatic retry to run')
          end)

          -- Commands work again: the next scheduled retry has to recover.
          helpers.wait_for(function()
            return repo.error_count == 0 and repo.last_error == nil
          end, 'the retry to succeed once commands work again')
        end)
      end)
    end),
  },
  {
    name = 'a definitive negative deletes the repository instead of retrying',
    fn = guarded(function()
      local dir = helpers.scratch_dir('runtime-negative')
      local calls = 0
      local repo = require('vcssign.repo').new({
        name = 'git',
        keyfile = '.git',
        metadata_dir = function()
          return nil
        end,
        get_root_async = function(_, cb)
          calls = calls + 1
          cb('fatal: not a git repository (or any of the parent directories): .git')
        end,
      }, dir)

      local deleted, errors = 0, 0
      repo:on_delete(function()
        deleted = deleted + 1
      end)
      repo:on_error(function()
        errors = errors + 1
      end)

      repo:refresh_now()
      helpers.wait_for(function()
        return repo.is_deleted
      end, 'the repository to be deleted')
      eq(calls, 1, 'a definitive negative must not be retried')
      eq(deleted, 1, 'on_delete must fire exactly once')
      eq(errors, 0, 'an answer is not an error')
      eq(repo._retry_timer, nil, 'no retry may be armed for a gone repository')
      repo:dispose()
    end),
  },
  {
    name = 'a vanished .git disposes the repository and frees every handle',
    fn = guarded(function()
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
    end),
  },
  {
    name = 'deleting an svn working copy cancels its watcher too',
    fn = guarded(function()
      local dir = helpers.svn_checkout('runtime-svn')
      local fs_baseline = helpers.uv_count('fs_event')
      helpers.with_repo('spec:svn', dir, function(repo)
        eq(repo.system.name, 'svn')
        ok(repo.watch_paths[vim.fs.normalize(repo.metadata_path)], 'the .svn watch must be up')

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
    end),
  },
  {
    name = 'a queued refresh callback is released when the repository goes away',
    fn = guarded(function()
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
    end),
  },
  {
    name = 'a detach that races an in-flight attach does not leak a reference',
    fn = guarded(function()
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
    end),
  },
  {
    name = 'a probe that reports after dispose changes nothing',
    fn = guarded(function()
      -- A stub adapter, so the timing is fully controlled: the "probe" reports
      -- back 30ms after a dispose that happens while it runs.
      local reported = false
      local system = {
        name = 'stub',
        keyfile = '.stub',
        metadata_dir = function()
          return nil
        end,
        get_root_async = function(_, cb)
          vim.defer_fn(function()
            reported = true
            cb(nil, helpers.plugin_root)
          end, 30)
        end,
      }
      local repo = require('vcssign.repo').new(system, helpers.plugin_root)
      local errors, updates = 0, 0
      repo:on_error(function()
        errors = errors + 1
      end)
      repo:on_update(function()
        updates = updates + 1
      end)

      repo:refresh_now()
      ok(repo.is_updating, 'the probe must be in flight')
      repo:dispose()

      helpers.wait_for(function()
        return reported
      end, 'the stubbed probe to report back')
      vim.wait(50, function()
        return false
      end)
      eq(repo.is_updating, false, 'the in-flight flag must still be cleared')
      eq(repo.error_count, 0, 'a late answer must not touch the error state')
      eq(repo.last_error, nil)
      eq(errors, 0, 'on_error must not fire for a disposed repo')
      eq(updates, 0, 'on_update must not fire for a disposed repo')
      eq(repo._retry_timer, nil, 'and no retry timer may be armed')
    end),
  },
  {
    name = 'staging inside a linked worktree is watched through the gitdir target',
    fn = guarded(function()
      -- `.git` is a *file* here and the index lives in the main repository, so
      -- this only works if the metadata directory is resolved, not assumed.
      local worktree = helpers.git_worktree('runtime-worktree')
      helpers.with_repo('spec:worktree', worktree, function(repo)
        eq(repo.system.name, 'git')
        ok(
          repo.metadata_path ~= nil and repo.metadata_path ~= worktree .. '/.git',
          'the metadata directory must be the gitdir target, got ' .. tostring(repo.metadata_path)
        )
        eq(vim.uv.fs_stat(repo.metadata_path).type, 'directory')
        ok(
          repo.watch_paths[vim.fs.normalize(repo.metadata_path)],
          'the gitdir target must be the watched directory'
        )

        local updates = 0
        repo:on_update(function()
          updates = updates + 1
        end)
        vim.wait(250, function()
          return false
        end)
        local baseline = updates

        -- The index change lands in the *main* repository's gitdir, which is
        -- exactly why a keyfile-only watcher would miss it.
        helpers.write(worktree .. '/base.txt', 'edited\n')
        helpers.sh({ 'git', '-C', worktree, 'add', 'base.txt' })
        helpers.wait_for(function()
          return updates > baseline
        end, 'the index change inside the worktree gitdir to be picked up')
      end)
    end),
  },
  {
    name = 'references share one repo and the last release disposes it',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-refs')
      local fs_baseline = helpers.uv_count('fs_event')

      local err_a, repo_a = helpers.wait(function(cb)
        repo_manager.attach('spec:ref-a', dir, cb)
      end)
      eq(err_a, nil)
      eq(repo_manager.count(), 1)
      eq(repo_manager.ref_count(dir), 1)
      ok(helpers.uv_count('fs_event') > fs_baseline)

      -- An in-sync repository is served by the existing object without a probe.
      local probes = count_probes(function()
        local err_b, repo_b = helpers.wait(function(cb)
          repo_manager.attach('spec:ref-b', dir .. '/base.txt', cb)
        end)
        eq(err_b, nil)
        ok(repo_b == repo_a, 'the second reference must reuse the same Repo object')
      end)
      eq(probes, 0, 'an attached reference is served without spawning a VCS command')
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
    end),
  },
  {
    name = 'dispose_all leaves nothing behind',
    fn = guarded(function()
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
    end),
  },
  {
    name = 'path lookups are case-insensitive on Windows',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-case')
      -- Flip the drive letter: the same directory on Windows, a different string.
      local flipped = dir:sub(1, 1):lower() .. dir:sub(2)
      if flipped == dir then
        return -- POSIX: nothing to assert, paths really are case-sensitive
      end
      helpers.with_repo('spec:case', dir, function(repo)
        ok(repo_manager.get(flipped) == repo, 'get() must resolve the repository')
        eq(repo_manager.ref_count(flipped), 1)
        ok(repo_manager.get_by_path(flipped .. '/base.txt') == repo, 'and a file path in it')
      end)
    end),
  },
  {
    name = 'the repository root itself maps back to the repository',
    fn = guarded(function()
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
    end),
  },
  {
    name = 'dispose_all cancels an attach that is still detecting',
    fn = guarded(function()
      -- Regression: `dispose_all` left the generation counter alone, so a
      -- detection still in flight would create a repository (with a watcher
      -- and a probe) *after* everything was disposed.
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
    end),
  },
  {
    name = 'active() resolves the repository of the current buffer',
    fn = guarded(function()
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
    end),
  },
}
