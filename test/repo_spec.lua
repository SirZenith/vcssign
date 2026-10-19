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

--- Count how many *liveness probes* `fn` causes, for the repository `fn` works
--- on.
---
--- `repo.lua` reaches the adapters through module tables, so wrapping `exec.run`
--- here is seen by every command the plugin spawns — no test hook in
--- production code.  The probe is `git rev-parse --show-toplevel` (or
--- `svn info --show-item wc-root`), so nothing else counts.
---
--- The count is scoped to the **first** cwd that probes: in a full run a
--- leftover repository from an earlier spec can still answer its watcher
--- inside these (long) windows, and counting that one too made this case red
--- only in full runs (2026-10-17: `229 tests, 1 failed` on
--- `runtime-manual-coalesce`, green when `repo_spec` runs alone).  `fn` always
--- starts by touching the repository under test, so the first probe names it.
---@param fn fun()
---@return integer
local function count_probes(fn)
  local real_run = exec.run
  local calls = 0
  local subject = nil
  exec.run = function(cmd, opts, cb)
    local joined = table.concat(cmd, ' ')
    if joined:find('rev-parse', 1, true) or joined:find('wc-root', 1, true) then
      local cwd = opts and opts.cwd
      subject = subject or cwd
      if cwd == subject then
        calls = calls + 1
      end
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

--- Count how many *status queries* `fn` spawns.
---
--- Same trick as `count_probes` above — `repo.lua` reaches the adapters through
--- module tables, so wrapping `exec.run` sees every command — with the filter
--- being the subcommand only the status view uses (`git status` / `svn status`).
---@param fn fun()
---@return integer
local function count_status(fn)
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
    name = 'a root the detector resolved costs no second probe (M7 P0-5)',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-first')
      local probes = count_probes(function()
        helpers.with_repo('spec:first', dir, function(repo)
          eq(repo.system.name, 'git')
          eq(repo.root, dir)
          -- `detect_async` asked git for this root one command ago, so the
          -- runtime starts out loaded and `_bind` may answer without spawning.
          ok(repo.has_loaded, 'the handed-over root counts as loaded')
          eq(repo.is_dirty, false, 'nothing is outstanding, so no probe is owed')
          eq(repo.error_count, 0)
          -- No `entries()`/`get_status()` any more (D38); the metadata watch is
          -- the only handle it keeps.
          ok(
            repo.watch_paths[vim.fs.normalize(repo.metadata_path)],
            'the metadata directory must be watched'
          )
        end)
      end)
      eq(probes, 1, 'the first attach spawns the detector probe and nothing more')
    end),
  },
  {
    name = 'a working copy is resolved once too, not once per layer',
    fn = guarded(function()
      local dir = helpers.svn_repo('runtime-first-svn')
      local probes = count_probes(function()
        helpers.with_repo('spec:first-svn', dir, function(repo)
          eq(repo.system.name, 'svn')
          ok(repo.has_loaded, 'the handed-over working copy root counts as loaded')
        end)
      end)
      eq(probes, 1, 'one `svn info --show-item wc-root`, from the detector only')
    end),
  },
  {
    name = 'a later trigger still probes a repository that skipped its first one',
    fn = guarded(function()
      -- The liveness answer was borrowed from detection, not skipped forever.
      local dir = helpers.git_repo('runtime-first-later')
      helpers.with_repo('spec:later', dir, function(repo)
        eq(repo.has_loaded, true)
        local probes = count_probes(function()
          helpers.wait(function(cb)
            repo:refresh_now(cb)
          end)
        end)
        eq(probes, 1, 'an explicit refresh asks the VCS again')
        eq(repo.is_dirty, false)
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
      -- The root has to be watched as well: a handler on the metadata
      -- directory itself never reports that directory going away.
      ok(repo.watch_paths[repo.metadata_path], 'the metadata directory must be watched')
      ok(repo.watch_paths[vim.fs.normalize(dir)], 'the root must be watched for liveness')
      -- git spreads its store over the git directory (index, HEAD, refs), so
      -- the metadata watch is recursive wherever libuv can do that
      -- (08 §3.5 S1).
      eq(
        repo.watch_recursive[repo.metadata_path],
        vim.uv.os_uname().sysname ~= 'Linux',
        'git needs the recursive watch, svn does not'
      )

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

  {
    name = 'a work tree event announces the file it touched',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-changed-path')
      helpers.with_repo('spec:changed-path', dir, function(repo)
        vim.wait(300, function()
          return false
        end)
        local announced = {}
        repo:on_update(function(_, changed)
          announced[#announced + 1] = changed
        end)
        -- The root watch is non-recursive, which is the one place libuv hands
        -- us a filename (08 P0-3).  The metadata watch never does: the index /
        -- wc.db is one store for every file in the repository.
        helpers.write(dir .. '/base.txt', 'edited on disk\n')
        helpers.wait_for(function()
          return #announced > 0
        end, 'the work tree event')
        vim.wait(400, function()
          return false
        end)

        local named, saw_all = {}, false
        for _, changed in ipairs(announced) do
          if changed == nil then
            saw_all = true
          else
            for path in pairs(changed) do
              named[path] = true
            end
          end
        end
        eq(saw_all, false, 'a work tree event names a path, it does not shrug')
        eq(named[vim.fs.normalize(dir .. '/base.txt')], true, 'the file the event named')
        eq(vim.tbl_count(named), 1, 'and no other file')
      end)
    end),
  },
  {
    name = 'a metadata change announces no path, because it moves every baseline',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-changed-meta')
      helpers.with_repo('spec:changed-meta', dir, function(repo)
        vim.wait(300, function()
          return false
        end)
        local saw_all = false
        repo:on_update(function(_, changed)
          saw_all = saw_all or changed == nil
        end)
        -- `git add` rewrites `.git/index`.  The write before it names a path,
        -- the staging does not — and the staging is the one every buffer has to
        -- react to.
        helpers.write(dir .. '/base.txt', 'edited\n')
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        helpers.wait_for(function()
          return saw_all
        end, 'the metadata event')
        eq(saw_all, true, 'the index is one store for the whole repository')
      end)
    end),
  },
  {
    name = 'a probe with no filesystem event behind it announces an empty set',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-changed-none')
      helpers.with_repo('spec:changed-none', dir, function(repo)
        vim.wait(300, function()
          return false
        end)
        local answered, changed_at = false, nil
        repo:on_update(function(_, changed)
          answered, changed_at = true, changed
        end)
        -- `FocusGained`, `:Vcssign refresh`, an action's post-step: all of them
        -- ask "look again" without claiming anything moved.  An empty set is
        -- how that is said, so the sign layer can skip every buffer.
        repo:refresh()
        helpers.wait_for(function()
          return answered
        end, 'the announcement')
        eq(type(changed_at), 'table', 'nothing moved must not mean "assume everything"')
        eq(next(changed_at), nil, 'an empty set of paths')
      end)
    end),
  },
  {
    name = 'an svn metadata change announces no path either',
    fn = guarded(function()
      local dir = helpers.svn_repo('runtime-changed-svn')
      helpers.with_repo('spec:changed-svn', dir, function(repo)
        eq(repo.system.name, 'svn')
        vim.wait(400, function()
          return false
        end)
        local saw_all = false
        repo:on_update(function(_, changed)
          saw_all = saw_all or changed == nil
        end)
        -- A commit rewrites `.svn/wc.db`, the file BASE is read through — the
        -- svn anchor of the same rule (08 §3.5).
        helpers.write(dir .. '/base.txt', 'committed\n')
        helpers.sh({ 'svn', 'commit', '-q', '-m', 'changed', dir .. '/base.txt' })
        helpers.wait_for(function()
          return saw_all
        end, 'the svn metadata event')
        eq(saw_all, true)
      end)
    end),
  },

  {
    name = 'one status query answers the whole repository, and it is cached',
    fn = guarded(function()
      local dir = helpers.git_repo('repo-status-cache')
      helpers.write(dir .. '/base.txt', 'base\none\n')
      helpers.with_repo('spec:status-cache', dir, function(repo)
        local calls = count_status(function()
          local _, first, trusted = helpers.wait(function(cb)
            repo:status(cb)
          end)
          ok(trusted, 'the answer is trusted: the store did not move')
          eq(first[dir .. '/base.txt'].worktree, true, 'and it can see the change')

          local _, second = helpers.wait(function(cb)
            repo:status(cb)
          end)
          ok(second == first, 'the second caller is handed the cached table')
        end)
        eq(calls, 1, 'two callers, one query')
      end)
    end),
  },

  {
    name = 'a worktree event is folded into the cached view instead of retiring it',
    fn = guarded(function()
      local dir = helpers.git_repo('repo-status-patch')
      helpers.write(dir .. '/base.txt', 'base\none\n')
      helpers.with_repo('spec:status-patch', dir, function(repo)
        local _, entries = helpers.wait(function(cb)
          repo:status(cb)
        end)
        local path = dir .. '/base.txt'
        eq(entries[path].worktree, true)

        local folded = {}
        local real_note = repo._note_status_change
        repo._note_status_change = function(self, changed)
          folded[#folded + 1] = changed
          return real_note(self, changed)
        end
        helpers.write(path, 'base\ntwo\n')
        local ok_note, note_err = pcall(helpers.wait_for, function()
          return #folded > 0
        end, 'the event to be folded into the view')
        repo._note_status_change = real_note
        if not ok_note then
          error(note_err, 0)
        end
        eq(folded[1], path, 'the event named the file')

        local calls = count_status(function()
          local _, again = helpers.wait(function(cb)
            repo:status(cb)
          end)
          ok(again == entries, 'the same table survived the write')
        end)
        eq(calls, 0, 'a save costs no query at all')
      end)
    end),
  },

  {
    name = 'a metadata change retires the view, because it can move everything',
    fn = guarded(function()
      local dir = helpers.git_repo('repo-status-retire')
      helpers.write(dir .. '/base.txt', 'base\none\n')
      helpers.with_repo('spec:status-retire', dir, function(repo)
        local _, first, trusted = helpers.wait(function(cb)
          repo:status(cb)
        end)
        ok(trusted)
        eq(first[dir .. '/base.txt'].staged, false, 'the change is unstaged')

        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        helpers.wait_for(function()
          return repo.status_cache == nil
        end, 'the view to be retired by the index event')

        local calls = count_status(function()
          local _, second, again_trusted = helpers.wait(function(cb)
            repo:status(cb)
          end)
          ok(again_trusted, 'the fresh answer is trusted again')
          eq(second[dir .. '/base.txt'].staged, true, 'and it sees the staging')
        end)
        eq(calls, 1, 'the retired view is asked again, once')
      end)
    end),
  },

  {
    name = 'a view taken before the store moved is never believed about staging',
    fn = guarded(function()
      local dir = helpers.git_repo('repo-status-stale')
      helpers.with_repo('spec:status-stale', dir, function(repo)
        local _, first = helpers.wait(function(cb)
          repo:status(cb)
        end)
        eq(first[dir .. '/base.txt'], nil, 'a clean file has no entry at all')

        -- Staged behind the watcher's back: whether or not the event has landed
        -- by the time of the next call, the answer must not claim "not staged".
        helpers.write(dir .. '/base.txt', 'base\none\n')
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        local _, second, trusted = helpers.wait(function(cb)
          repo:status(cb)
        end)
        ok(trusted, 'the store is quiet now, so the answer is trusted')
        eq(second[dir .. '/base.txt'].staged, true, 'the staging is visible')
      end)
    end),
  },

  {
    name = 'the batch reader serves every read, and is closed with the repository',
    fn = guarded(function()
      local dir = helpers.git_repo('runtime-reader')
      helpers.with_repo('spec:reader', dir, function(repo)
        local git = require('vcssign.vcs.git')
        local _, shown = helpers.wait(function(cb)
          git.show(dir, 'HEAD', 'base.txt', cb)
        end)
        local _, first = helpers.wait(function(cb)
          repo:read_blob('HEAD', 'base.txt', cb)
        end)
        eq(first, shown, 'the reader answers exactly what the command answers')
        local reader = repo._reader
        ok(reader ~= nil and not reader.closed, 'a reader is open')

        local _, second = helpers.wait(function(cb)
          repo:read_blob('index', 'base.txt', cb)
        end)
        eq(second, first, 'the staged blob is the same text')
        eq(repo._reader, reader, 'the same child answered both')

        repo:dispose()
        ok(reader.closed, 'dispose closes the child instead of leaking it')
      end)
    end),
  },
  {
    name = 'a reader started before the index moved is replaced, not believed',
    fn = guarded(function()
      -- Measured, and the reason this case exists: a `cat-file --batch` child
      -- reads the index once, so after `git apply --cached` the same child keeps
      -- answering with the *previous* blob.  Staging a hunk looked like it had
      -- not happened at all (attach_spec "the sign layers to split" timed out)
      -- until the reader started being retired when the store moves.
      local dir = helpers.git_repo('runtime-reader-stale')
      helpers.with_repo('spec:reader-stale', dir, function(repo)
        local _, before = helpers.wait(function(cb)
          repo:read_blob('index', 'base.txt', cb)
        end)
        local first = repo._reader
        ok(first ~= nil and not first.closed, 'a reader is open')

        helpers.write(dir .. '/base.txt', 'staged text' .. string.char(10))
        helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
        local _, after = helpers.wait(function(cb)
          repo:read_blob('index', 'base.txt', cb)
        end)
        eq(
          after,
          'staged text' .. string.char(10),
          'the moved index is what is read, not the cached one'
        )
        ok(after ~= before, 'which is a different answer from before')
        ok(repo._reader ~= first, 'the stale child is not reused')
        ok(first.closed, 'and it is closed rather than leaked')
      end)
    end),
  },
}
