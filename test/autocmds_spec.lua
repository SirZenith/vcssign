--- Lifecycle autocmd specs.
---
--- Two things are worth testing here and nothing else is: that a *trigger*
--- (entering a file, writing it, `:cd`, focus) actually reaches the signs
--- pipeline, and that nothing outlives its buffer or the session.  The policy
--- (one cache per root, one command per debounce window) is `repo_spec`'s job;
--- the pipeline itself is `attach_spec`'s.
--- See loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md §6.
local attach = require('vcssign.attach')
local autocmds = require('vcssign.autocmds')
local config = require('vcssign.config')
local helpers = require('helpers')
local manager = require('vcssign.repo_manager')
local signs = require('vcssign.signs')

--- Repositories, buffers, autocmds, windows, cwd: everything a case can leave
--- behind, in the order that does not re-enter.
local function reset()
  autocmds.disable()
  attach.forget_all()
  manager.dispose_all()
  vim.cmd('silent! tabonly')
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('only')
  end
  vim.cmd('silent! enew!')
  vim.cmd('cd ' .. vim.fn.fnameescape(helpers.plugin_root))
end

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

--- A git repo with one modified file, unattached.
---@param name string
---@return string dir
local function repo_dir(name)
  local dir = helpers.git_repo(name)
  helpers.write(dir .. '/base.txt', 'changed\n')
  return dir
end

---@param dir string
local function edit_file(dir)
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
end

--- Does `dir` have a repository attached?
---@param dir string
---@return boolean
local function attached(dir)
  return manager.get_by_path(dir) ~= nil
end

-- `helpers.capture_notify` with the optional wait predicate: the VCS answers
-- asynchronously, so a case has to wait for its notification while the stub
-- is still in place.
local collect = helpers.capture_notify
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

--- The events the augroup watches.
---@return table<string, boolean>
local function watched()
  local events = {}
  -- A deleted group is the expected state after `disable()`, and asking about
  -- it raises rather than returning nothing.
  local ok, autocmds_list = pcall(vim.api.nvim_get_autocmds, { group = autocmds.group_name })
  for _, autocmd in ipairs(ok and autocmds_list or {}) do
    events[autocmd.event] = true
  end
  return events
end

return {
  {
    name = 'setup() watches the lifecycle events, once',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local events = watched()
      for _, event in ipairs({
        'BufReadPost',
        'BufEnter',
        'BufWritePost',
        'BufDelete',
        'BufWipeout',
        'DirChanged',
        'FocusGained',
        -- `ColorScheme` re-resolves the sign groups' candidate chain.
        'ColorScheme',
        'VimLeavePre',
      }) do
        eq(events[event], true, event .. ' is watched')
      end
      -- Calling setup() again replaces the group instead of doubling it: two
      -- BufEnter handlers would attach every buffer twice.
      autocmds.setup()
      eq(#vim.api.nvim_get_autocmds({ group = autocmds.group_name, event = 'BufEnter' }), 1)
      -- The `ColorScheme` handler is one global autocmd, not one per buffer: a
      -- second `setup()` must not double it either.
      eq(#vim.api.nvim_get_autocmds({ group = autocmds.group_name, event = 'ColorScheme' }), 1)
    end),
  },
  {
    name = 'opening a file attaches it and draws its signs, once per buffer',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-bufenter')
      edit_file(dir)
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to be attached and rendered')
      local repo = manager.get_by_path(dir)
      local refs = manager.ref_count(repo.root)
      ok(refs >= 1, 'at least the buffer reference')
      eq(attach.count(), 1)
      ok(signs.sign_count(bufnr) > 0, 'and the modified line is signposted')

      -- Re-entering the same buffer must not attach it twice: `BufEnter` fires
      -- on every window switch, and both the reference and the pipeline state
      -- are keyed by buffer.
      vim.cmd('enew')
      vim.cmd('buffer ' .. bufnr)
      vim.wait(100, function()
        return false
      end)
      eq(manager.ref_count(repo.root), refs)
      eq(manager.count(), 1, 'and no second repository appeared')
      eq(attach.count(), 1, 'and no second pipeline state either')
    end),
  },
  {
    name = 'setup() attaches the buffer a window shows, a late load included',
    fn = guarded(function()
      reset()
      local dir = repo_dir('autocmd-late-setup')
      -- The file (and with it `BufReadPost` / `BufEnter`) comes first and the
      -- plugin is configured only afterwards — what a lazy trigger on
      -- `BufEnter` does.  The event that would have attached the buffer has
      -- already fired, so the sweep in `setup()` is the only thing left.
      edit_file(dir)
      autocmds.setup()
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer opened before setup() to be attached and rendered')
      eq(attach.count(), 1)
      ok(signs.sign_count(bufnr) > 0, 'and the modified line is signposted')
    end),
  },
  {
    name = 'setup() leaves a loaded buffer that no window shows to its own BufEnter',
    fn = guarded(function()
      reset()
      local dir = repo_dir('autocmd-late-setup-hidden')
      -- The sweep follows the windows, not the loaded buffer list: a buffer
      -- nobody shows is attached by its `BufEnter` when it becomes visible,
      -- and a plugin configured late must not mount repositories for the
      -- whole session's leftovers.
      edit_file(dir)
      vim.cmd('enew')
      autocmds.setup()
      vim.wait(200, function()
        return false
      end)
      eq(attach.count(), 0, 'nothing is attached while the file is hidden')
      vim.cmd('buffer ' .. vim.fn.bufnr(dir .. '/base.txt'))
      helpers.wait_for(function()
        local st = attach.state(vim.fn.bufnr(dir .. '/base.txt'))
        return st ~= nil and st.attached
      end, 'showing the buffer again to attach it through `BufEnter`')
      eq(attach.count(), 1)
    end),
  },
  {
    name = 'reloading the buffer re-attaches it and redraws',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-reload')
      edit_file(dir)
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to be attached')

      -- Changed on disk behind the editor's back, then `:e!`: the buffer is
      -- unloaded (which fires the attach pipeline's `on_detach`) and read
      -- again (BufReadPost).  Both halves have to come back, or the signs
      -- would silently stay behind on the old state.
      helpers.write(dir .. '/base.txt', 'changed\nextra\n')
      vim.cmd('edit!')
      helpers.wait_for(function()
        local hunks = attach.hunks(bufnr)
        return attach.state(bufnr) ~= nil and #hunks == 1 and hunks[1].added.count == 2
      end, 'the reloaded buffer to be re-attached and re-drawn')
      eq(attach.count(), 1, 'exactly one state, not a leaked one')
      ok(signs.sign_count(bufnr) > 0)
      eq(manager.ref_count(dir), 1, 'and the reference is still held exactly once')
    end),
  },
  {
    name = 'BufWritePost re-reads the baseline right away',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-bufwrite')
      edit_file(dir)
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to be attached')

      -- The index catches up with the worktree outside the editor: now the
      -- *baseline* moved, and a write is the trigger that re-reads it.
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      local calls = {}
      local real = attach.refresh
      attach.refresh = function(b, cb)
        calls[#calls + 1] = b
        return real(b, cb)
      end
      local ok, err = pcall(function()
        -- A headless editor writes no files in these cases, so the event is
        -- delivered the way the editor would deliver it.
        vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
        helpers.wait_for(function()
          return #attach.hunks(bufnr) == 0
        end, 'the write to re-read the baseline')
      end)
      attach.refresh = real
      if not ok then
        error(err, 0)
      end
      eq(calls, { bufnr }, 'the write reached the buffer refresh')
      eq(signs.sign_count(bufnr), 0, 'and the sign went away with the hunk')
    end),
  },
  {
    name = 'a save keeps the signs of a clean file, against its real baseline',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = helpers.git_repo('autocmd-save-subdir')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/sub/nested.txt'))
      local bufnr = vim.api.nvim_get_current_buf()
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.ready
      end, 'the buffer to be attached')
      local st = attach.state(bufnr)
      eq(st.base_text, 'nested', 'the baseline is BASE, not the buffer')

      vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { 'one' })
      vim.cmd('silent write')

      -- The save moves nothing in `.git/index`, so the status view used to
      -- still call this file clean; `from_buffer` then made the saved text its
      -- own baseline and every sign disappeared (D51).
      eq(st.base_text, 'nested', 'a save does not replace the baseline')
      eq(#attach.hunks(bufnr), 1, 'the hunk survives the save')
      eq(signs.sign_count(bufnr), 1, 'and so does its sign')
    end),
  },
  {
    name = 'a buffer outside any repository attaches nothing, quietly',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local file = vim.fn.tempname() .. '.txt'
      vim.fn.mkdir(vim.fs.dirname(file), 'p')
      vim.fn.writefile({ 'hello' }, file)
      local seen = collect(function()
        vim.cmd('edit ' .. vim.fn.fnameescape(file))
        local bufnr = vim.api.nvim_get_current_buf()
        -- Detection is asynchronous (two VCS probes here), so wait for it to
        -- come up empty rather than for a wall-clock guess.
        helpers.wait_for(function()
          local st = attach.state(bufnr)
          return st ~= nil and st.enabled == false
        end, 'the detection to come up empty')
      end)
      eq(manager.count(), 0)
      eq(attach.count(), 0, 'no sign pipeline either')
      -- And nothing was said about it either: most files are not in a
      -- repository, and a notification per file would be unusable.
      eq(
        #seen,
        0,
        'no message about a file that is simply not in a repository: '
          .. helpers.describe_notifications(seen)
      )
      vim.fn.delete(file)
    end),
  },
  {
    name = 'deleting the buffer releases the repository',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-bufdelete')
      edit_file(dir)
      helpers.wait_for(function()
        return attached(dir)
      end, 'the repository to be attached')
      local bufnr = vim.api.nvim_get_current_buf()
      eq(manager.ref_count(dir), 1)

      vim.cmd('enew')
      vim.api.nvim_buf_delete(bufnr, { force = true })
      helpers.wait_for(function()
        return not attached(dir)
      end, 'the repository to be released with its last buffer')
      eq(attach.state(bufnr), nil, 'the pipeline state went with it')
      eq(helpers.uv_count('fs_event'), 0, 'and its watcher closed')
    end),
  },
  {
    name = 'FocusGained refreshes what is already attached',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-focus')
      edit_file(dir)
      helpers.wait_for(function()
        return attached(dir)
      end, 'the repository to be attached')
      local repo = manager.get_by_path(dir)
      -- Changed behind our back, with the watcher deliberately not involved:
      -- this is the Windows fallback path the event exists for.
      helpers.write(dir .. '/external.txt', 'from outside\n')

      -- `Repo` does not cache status any more (D38), so the refresh pass itself
      -- is what the event can be asserted against.
      local passes = helpers.count_refreshes(repo)
      -- A headless editor never receives terminal focus, so the event is
      -- delivered the way the editor would deliver it.
      vim.api.nvim_exec_autocmds('FocusGained', {})
      helpers.wait_for(function()
        return passes() > 0
      end, 'the external change to be picked up')
    end),
  },
  {
    name = 'changing the directory attaches the new one',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-dirchanged')
      vim.cmd('cd ' .. vim.fn.fnameescape(dir))
      helpers.wait_for(function()
        return attached(dir)
      end, 'the cwd repository to be attached')
      eq(manager.get_by_path(dir).root:lower(), dir:lower(), 'the repository of the new cwd')

      -- `:lcd` fires the same event but does not change the *global* directory,
      -- so it must not rebind the reference to an unrelated repository.
      local lcd_target = vim.fn.tempname()
      vim.fn.mkdir(lcd_target, 'p')
      vim.cmd('lcd ' .. vim.fn.fnameescape(lcd_target))
      vim.wait(100, function()
        return false
      end)
      eq(manager.get(dir) ~= nil, true, 'a window-local cwd change is ignored')
      vim.cmd('cd ' .. vim.fn.fnameescape(dir))

      -- Moving out again releases the 'cwd' reference (attach detaches a
      -- reference whose detection comes up empty), and the next directory
      -- rebinds it rather than piling up.
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, 'p')
      vim.cmd('cd ' .. vim.fn.fnameescape(elsewhere))
      helpers.wait_for(function()
        return not attached(dir)
      end, 'the cwd repository to be released')
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'on_attach and on_detach hooks fire, and a broken one is isolated',
    fn = guarded(function()
      reset()
      local attached_repos, detached_repos = {}, {}
      with_config({
        on_attach = function(repo)
          attached_repos[#attached_repos + 1] = repo.root
        end,
        on_detach = function(repo)
          detached_repos[#detached_repos + 1] = repo.root
          error('a user hook that raises')
        end,
      }, function()
        autocmds.setup()
        local dir = repo_dir('autocmd-hooks')
        edit_file(dir)
        helpers.wait_for(function()
          return #attached_repos > 0
        end, 'on_attach to fire')
        eq(attached_repos[1]:lower(), dir:lower())

        local notification = helpers.capture_notify_one(function()
          vim.cmd('enew')
          vim.api.nvim_buf_delete(vim.fn.bufnr(dir .. '/base.txt'), { force = true })
          helpers.wait_for(function()
            return #detached_repos > 0
          end, 'on_detach to fire')
        end, 'on_detach hook failed')
        eq(detached_repos[1]:lower(), dir:lower())
        -- The hook raised inside the detach path: the repository still went, and
        -- the failure was reported (an ERROR, not a silent swallow).
        eq(manager.get_by_path(dir), nil)
        eq(notification.level, vim.log.levels.ERROR)
        ok(notification.message:find('on_detach hook failed', 1, true), notification.message)
      end)
    end),
  },
  {
    name = 'VimLeavePre leaves no repository or watcher behind',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-leavepre')
      edit_file(dir)
      helpers.wait_for(function()
        return attached(dir)
      end, 'the repository to be attached')
      local repo = manager.get_by_path(dir)
      eq(helpers.uv_count('fs_event') > 0, true, 'there is a watcher to leak')

      -- Let the first liveness probe land first: an `exec` command that is
      -- still in flight keeps its own timeout timer until the child answers,
      -- and VimLeavePre (which does not kill running commands) cannot change
      -- that.  What is asserted here is the settled case: nothing the plugin
      -- *owns* survives the teardown.
      helpers.wait_for(function()
        return repo.has_loaded and not repo.is_updating
      end, 'the first liveness probe to finish')
      -- The buffer's own pipeline reads the baseline in `exec` commands of its
      -- own, so wait for it to have drawn its signs: only then is no `exec`
      -- still in flight holding a timeout timer.
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer pipeline to settle')

      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      eq(manager.count(), 0, 'no repositories')
      eq(attach.count(), 0, 'no attached buffers')
      eq(helpers.uv_count('fs_event'), 0, 'no watch handles')
      eq(helpers.uv_count('timer'), 0, 'and no timers')
    end),
  },
  {
    name = 'teardown survives when the buffer is the last window',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = repo_dir('autocmd-last-window')
      edit_file(dir)
      helpers.wait_for(function()
        return attached(dir)
      end, 'the repository to be attached')
      -- The buffer is the only window: closing it (or closing the tab) raises
      -- E444, so the teardown must not rely on a window close succeeding to
      -- release the watchers.
      eq(#vim.api.nvim_tabpage_list_wins(0), 1)

      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      eq(manager.count(), 0, 'the repositories still went')
      eq(helpers.uv_count('fs_event'), 0, 'no watcher was left behind')
    end),
  },
  {
    name = 'disable() is idempotent and stops the triggers',
    fn = guarded(function()
      reset()
      autocmds.setup()
      autocmds.disable()
      autocmds.disable()
      eq(#vim.tbl_keys(watched()), 0, 'no autocmds left')

      local dir = repo_dir('autocmd-disabled')
      edit_file(dir)
      vim.wait(200, function()
        return false
      end)
      eq(manager.count(), 0, 'a disabled plugin does not attach anything')
    end),
  },
  {
    name = 'a save keeps the signs when the status view was repopulated at a newer stamp',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = helpers.git_repo('autocmd-save-newer-view')
      helpers.write(dir .. '/base.txt', 'base\none\ntwo\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'three lines' })
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
      local bufnr = vim.api.nvim_get_current_buf()
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.ready
      end, 'the buffer to be attached')
      local st = attach.state(bufnr)
      eq(st.base_text, 'base\none\ntwo', 'the baseline is the index')

      -- Another consumer repopulated the view at the *current* stamp - the one
      -- a save will ask under - while this buffer still holds an older one.
      -- The disk is clean, so that view legitimately calls base.txt clean, and
      -- a save must not let `from_buffer` turn that into "the buffer is the
      -- baseline" (D53).
      local repo = st.repo
      repo:_drop_status()
      helpers.wait(function(cb)
        repo:status(cb)
      end)
      eq(repo.status_cache[dir .. '/base.txt'], nil, 'the newer view says clean')
      st.base_stamp = 'older-view'

      -- Edit and save in one turn: a debounced refresh must not re-read the
      -- baseline in between, or the stale view would be replaced before the
      -- save sees it.
      vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'ONE' })
      vim.cmd('silent write')
      helpers.wait_for(function()
        return #attach.hunks(bufnr) == 1
      end, 'the save to keep the hunk against the real baseline')
      eq(st.base_text, 'base\none\ntwo\n', 'the save did not replace the baseline')
      eq(signs.sign_count(bufnr), 1, 'and the sign is still there')
    end),
  },
  {
    name = 'a save while the attach still decides retires the clean view',
    fn = guarded(function()
      reset()
      autocmds.setup()
      local dir = helpers.git_repo('autocmd-save-unknown-tracked')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
      local bufnr = vim.api.nvim_get_current_buf()
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.ready
      end, 'the buffer to be attached')
      local st = attach.state(bufnr)
      eq(st.base_text, 'base', 'the baseline is the index')

      -- The attach window: the view is warm and says base.txt is clean, but
      -- this buffer does not know yet whether the file is tracked - and an
      -- absent entry cannot tell "clean" from "ignored" (D50).  A save must
      -- not let that view baseline the saved text.
      st.ready = false
      st.tracked = nil
      vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'one' })
      vim.cmd('silent write')
      helpers.wait_for(function()
        return #attach.hunks(bufnr) == 1
      end, 'the save to keep the hunk against the real baseline')
      eq(st.base_text, 'base\n', 'the save did not replace the baseline')
      eq(signs.sign_count(bufnr), 1, 'and the sign is still there')
    end),
  },
}
