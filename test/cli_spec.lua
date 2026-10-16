--- `:Vcssign` command specs.
---
--- The command layer is where "which repository does the user mean" gets
--- answered, so the cases below are mostly about *targeting*: the sidebar's
--- cursor row, the current buffer's file, the only attached repository, and
--- what the user is told when none of them apply.
--- See impl/init/04-commands-actions.md §3, §6.
local autocmds = require('vcssign.autocmds')
local cli = require('vcssign.cli')
local config = require('vcssign.config')
local helpers = require('helpers')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local sidebar = require('vcssign.sidebar')

--- The configuration as it was when this file started: one case calls
--- `setup()`, and every later case would otherwise run with its options.
local DEFAULTS = vim.deepcopy(config.get())

--- Back to a clean editor between cases.  `cd` matters: several cases move the
--- cwd on purpose, and relative paths mean different things afterwards.
local function reset()
  sidebar.forget_all()
  manager.dispose_all()
  autocmds.disable()
  vim.cmd('silent! tabonly')
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('only')
  end
  vim.cmd('silent! enew!')
  vim.cmd('cd ' .. vim.fn.fnameescape(helpers.plugin_root))
  config.setup(vim.deepcopy(DEFAULTS))
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

-- `helpers.capture_notify` with the optional wait predicate: the VCS answers
-- asynchronously, so a case has to wait for its notification while the stub
-- is still in place.
local collect = helpers.capture_notify

--- A git repo with one modified file, *not* attached yet.
---@param name string
---@return string dir
local function repo_dir(name)
  local dir = helpers.git_repo(name)
  helpers.write(dir .. '/base.txt', 'changed\n')
  return dir
end

--- Run the command on a file buffer of `dir`, the way a user's `:Vcssign`
--- would see it (the buffer is what a path-less command resolves against).
---@param dir string
local function edit_file(dir)
  vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
end

return {
  {
    name = 'the command works before anything has attached the repository',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-toggle')
      edit_file(dir)
      eq(manager.count(), 0, 'nothing is tracked yet')

      cli.run({ 'toggle' })
      -- `ensure` has to detect and attach it first, then the sidebar opens and
      -- takes focus (toggle's semantics).
      helpers.wait_for(function()
        return vim.bo[vim.api.nvim_get_current_buf()].filetype == 'vcssign'
      end, 'the sidebar to open')
      eq(sidebar.open_count(), 1)
      eq(manager.count(), 1)
      ok(manager.get_by_path(dir .. '/base.txt') ~= nil, 'the repository is tracked now')

      -- No argument at all is the same as `toggle` (04 §3).
      cli.run({})
      eq(sidebar.open_count(), 0, 'pressing it again from the sidebar closes it')
      ok(sidebar.count() == 1, 'the buffer stays, so reopening is instant')
      -- D29: the command pins *the repository* for the session — one reference
      -- per repository, no matter how many commands (or how many files) name it.
      local held = manager.ref_count(dir)
      eq(held >= 2, true, 'the buffer and the command hold it')
      cli.run({ 'refresh', dir .. '/base.txt' })
      -- `debug` answers with a report; the point here is only that running
      -- another command does not add a reference (its message is swallowed so
      -- the suite's stderr stays clean).
      collect(function()
        cli.run({ 'debug' })
      end)
      eq(manager.ref_count(dir), held, 'asking again does not pile up references')
    end),
  },
  {
    name = 'close and open are separate verbs',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-open-close')
      edit_file(dir)
      cli.run({ 'open' })
      helpers.wait_for(function()
        return sidebar.open_count() == 1
      end, 'the sidebar to open')
      local repo = manager.get_by_path(dir)
      local win = sidebar.win(repo)
      -- Focus back to the file, then close by name.
      vim.api.nvim_set_current_win(vim.fn.bufwinid(vim.fn.bufnr(dir .. '/base.txt')))
      cli.run({ 'close' })
      eq(sidebar.open_count(), 0)
      eq(vim.api.nvim_win_is_valid(win), false)

      cli.run({ 'open' })
      helpers.wait_for(function()
        return sidebar.open_count() == 1
      end, 'the sidebar to reopen')
    end),
  },
  {
    name = 'an unknown subcommand lists the ones that exist',
    fn = guarded(function()
      reset()
      local seen = collect(function()
        cli.run({ 'stgae' })
      end)
      eq(seen[1].level, vim.log.levels.ERROR)
      ok(seen[1].message:find('unknown command', 1, true), seen[1].message)
      for _, name in ipairs(cli.subcommands) do
        ok(seen[1].message:find(name, 1, true), 'the message names ' .. name)
      end
    end),
  },
  {
    name = 'every advertised subcommand dispatches to a handler',
    fn = guarded(function()
      reset()
      -- A typo in the list would otherwise only show up in completion, where a
      -- wrong name is invisible until someone presses Tab and picks it.
      for _, name in ipairs(cli.subcommands) do
        local seen = collect(function()
          cli.run({ name })
        end)
        for _, notification in ipairs(seen) do
          ok(
            notification.message:find('unknown command', 1, true) == nil,
            string.format('%s: %s', name, notification.message)
          )
        end
      end
    end),
  },
  {
    name = 'stage <path> addresses a file without the sidebar being involved',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-stage-path')
      -- Current buffer deliberately somewhere else: the argument must win.
      vim.cmd('enew')
      local seen = collect(function()
        cli.run({ 'stage', dir .. '/base.txt' })
        helpers.wait_for(function()
          local repo = manager.get_by_path(dir)
          local found = repo and helpers.entry(repo:entries(), 'base.txt')
          return found ~= nil and found.status.index == 'modified'
        end, 'the file to be staged')
      end)
      ok(seen[1].message:find('staged base.txt', 1, true), seen[1].message)
      eq(
        helpers.sh({ 'git', '-C', dir, 'diff', '--cached', '--name-only' }):gsub('%s+$', ''),
        'base.txt'
      )
    end),
  },
  {
    name = 'a relative path argument resolves against the cwd',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-stage-relative')
      helpers.write(dir .. '/my file.txt', 'untracked\n')
      vim.cmd('cd ' .. vim.fn.fnameescape(dir))
      vim.cmd('enew')

      -- `<f-args>` splits an unescaped path on its spaces; the command puts the
      -- words back together instead of silently staging "my".
      local seen = collect(function()
        cli.run({ 'stage', 'my', 'file.txt' })
        helpers.wait_for(function()
          local repo = manager.get_by_path(dir)
          local found = repo and helpers.entry(repo:entries(), 'my file.txt')
          return found ~= nil and found.status.index == 'added'
        end, 'the file with a space to be staged')
      end)
      ok(seen[1].message:find('staged my file.txt', 1, true), seen[1].message)
    end),
  },
  {
    name = 'stage with no argument uses the sidebar row under the cursor',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-stage-cursor')
      vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/base.txt'))
      cli.run({ 'open' })
      helpers.wait_for(function()
        return sidebar.open_count() == 1
      end, 'the sidebar to open')
      local repo = manager.get_by_path(dir)
      local bufnr = sidebar.bufnr(repo)
      helpers.wait_for(function()
        return #renderer.items(bufnr) > 0
      end, 'the list to be drawn')
      local row
      for i, item in ipairs(renderer.items(bufnr)) do
        if item.entry and item.entry.rel_path == 'base.txt' then
          row = i
        end
      end
      vim.api.nvim_win_set_cursor(sidebar.win(repo), { row, 0 })

      collect(function()
        cli.run({ 'stage' })
        helpers.wait_for(function()
          local found = helpers.entry(repo:entries(), 'base.txt')
          return found ~= nil and found.status.index == 'modified'
        end, 'the file under the cursor to be staged')
      end)
      eq(
        helpers.sh({ 'git', '-C', dir, 'diff', '--cached', '--name-only' }):gsub('%s+$', ''),
        'base.txt'
      )
    end),
  },
  {
    name = 'outside every repository it says so, at INFO level',
    fn = guarded(function()
      reset()
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, 'p')
      vim.cmd('cd ' .. vim.fn.fnameescape(elsewhere))
      vim.cmd('enew')

      local seen = collect(function()
        cli.run({ 'toggle' })
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].level, vim.log.levels.INFO, 'not an error: most directories are not repositories')
      ok(seen[1].message:find('no repository found', 1, true), seen[1].message)
      ok(
        seen[1].message:find(elsewhere, 1, true),
        'and it names the path it looked at: ' .. seen[1].message
      )
      eq(sidebar.count(), 0)
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'debug reports the repositories, their caches and the watch handles',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-debug')
      edit_file(dir)
      cli.run({ 'open' })
      helpers.wait_for(function()
        return manager.count() == 1
      end, 'the repository to attach')

      local seen = collect(function()
        cli.run({ 'debug' })
      end)
      local report = seen[1].message
      eq(seen[1].level, vim.log.levels.INFO)
      ok(report:find('repositories', 1, true), report)
      ok(report:find(dir, 1, true), report)
      ok(report:find('entries=', 1, true), report)
      ok(report:find('refs=', 1, true), report)
      ok(report:find('watchers=', 1, true), report)
      ok(report:find('fs_event handles', 1, true), report)
      -- Two lines per repository at least: the summary and the repository.
      ok(#vim.split(report, '\n') >= 3, report)
    end),
  },
  {
    name = 'a repository nested inside an attached one is not mistaken for it',
    fn = guarded(function()
      reset()
      -- Outer and inner are both git repositories, which is the everyday shape
      -- (a submodule, a vendored checkout, a scratch directory inside a repo).
      local outer = helpers.git_repo('cli-nested-outer')
      helpers.write(outer .. '/base.txt', 'changed\n')
      local inner = helpers.git_repo('cli-nested-outer/inner')
      helpers.write(inner .. '/base.txt', 'changed\n')

      -- Attach the outer one first, e.g. by editing a file in it.
      edit_file(outer)
      cli.run({ 'open' })
      helpers.wait_for(function()
        return manager.get(outer) ~= nil
      end, 'the outer repository to attach')
      eq(manager.get(outer).root:lower(), outer:lower())

      -- Now a file from the inner repository: the deepest repository wins, or
      -- the sidebar (and every action behind it) would be showing the outer
      -- one's files.
      edit_file(inner)
      cli.run({ 'open' })
      -- Wait for the sidebar, not just the repository: the repository exists as
      -- soon as detection lands, while the sidebar opens once its first status
      -- run has answered.
      helpers.wait_for(function()
        local repo = manager.get(inner)
        return repo ~= nil and sidebar.bufnr(repo) ~= nil
      end, 'the inner repository to get its own sidebar')
      eq(manager.count(), 2)
      eq(manager.get(inner).root:lower(), inner:lower(), 'the inner repository is its own')
      eq(manager.get_by_path(inner .. '/base.txt').root:lower(), inner:lower())
      -- The sidebar that was opened is the inner one's.
      local bufnr = sidebar.bufnr(manager.get(inner))
      ok(bufnr ~= nil, 'the inner repository has a sidebar')
      ok(sidebar.bufnr(manager.get(outer)) ~= bufnr, 'and not the outer one, which has its own')
    end),
  },
  {
    name = 'the public API opens, closes and refreshes without a prior attach',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      local dir = repo_dir('cli-api-open')
      eq(manager.count(), 0)

      vcssign.open(dir .. '/base.txt')
      helpers.wait_for(function()
        return sidebar.open_count() == 1
      end, 'the sidebar to open')
      local repo = manager.get_by_path(dir)
      ok(repo ~= nil, 'and the repository is attached')

      vcssign.close(dir .. '/base.txt')
      eq(sidebar.open_count(), 0)
      vcssign.toggle(dir .. '/base.txt')
      helpers.wait_for(function()
        return sidebar.open_count() == 1
      end, 'toggle to reopen it')

      -- An external change, picked up by an explicit refresh.
      helpers.write(dir .. '/api.txt', 'untracked\n')
      vcssign.refresh(dir .. '/base.txt')
      helpers.wait_for(function()
        return helpers.entry(repo:entries(), 'api.txt') ~= nil
      end, 'the refresh to land')
    end),
  },
  {
    name = 'get_status answers from the cache and warms it up when it is cold',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      local dir = repo_dir('cli-api-status')

      -- Cold: no repository is attached, so there is nothing to answer with —
      -- but the call starts the work instead of blocking for it.
      eq(vcssign.get_status(dir .. '/base.txt'), nil)
      local repo
      helpers.wait_for(function()
        repo = manager.get_by_path(dir)
        return repo ~= nil and repo.has_loaded
      end, 'the background attach to finish')
      local status = vcssign.get_status(dir .. '/base.txt')
      eq(status.worktree, 'modified')
      eq(vcssign.get_status(dir .. '/sub/nested.txt'), nil, 'a clean file has no status')

      -- And the same for the list accessor.
      local entries = vcssign.get_entries(dir .. '/base.txt')
      eq(#entries, 1)
      eq(entries[1].rel_path, 'base.txt')
    end),
  },
  {
    name = 'the public API answers "no repository" the same way the command does',
    fn = guarded(function()
      reset()
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, 'p')
      vim.cmd('cd ' .. vim.fn.fnameescape(elsewhere))
      vim.cmd('enew')

      local vcssign = require('vcssign')
      local seen = collect(function()
        vcssign.toggle()
      end, function(s)
        return #s > 0
      end)
      -- INFO with the path, exactly like `:Vcssign toggle` (one implementation
      -- in `cli.report_no_repo`), not a bare unclassified message.
      eq(seen[1].level, vim.log.levels.INFO)
      ok(seen[1].message:find('no repository found', 1, true), seen[1].message)
      ok(seen[1].message:find(elsewhere, 1, true), seen[1].message)

      -- And an empty path is an answer too, not an assertion error.
      local empty = collect(function()
        vcssign.open('')
      end, function(s)
        return #s > 0
      end)
      ok(empty[1].message:find('no path given', 1, true), empty[1].message)
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'a nested repository is not answered with its parent cache',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      local outer = helpers.git_repo('cli-api-nested-outer')
      helpers.write(outer .. '/base.txt', 'changed\n')
      local inner = helpers.git_repo('cli-api-nested-outer/inner')
      helpers.write(inner .. '/base.txt', 'changed\n')

      -- Only the *outer* repository is attached (a buffer in it).
      edit_file(outer)
      cli.run({ 'open' })
      helpers.wait_for(function()
        return manager.get(outer) ~= nil
      end, 'the outer repository to attach')
      local outer_repo = manager.get(outer)
      helpers.wait_for(function()
        return outer_repo.has_loaded
      end, 'the outer status')
      -- The inner checkout shows up in the outer list as one row...
      helpers.wait_for(function()
        return helpers.entry(outer_repo:entries(), 'inner/') ~= nil
      end, 'the nested row')

      -- ...but the inner file's own status must come from the inner
      -- repository — which is not tracked yet, so the honest answer is "not
      -- yet", not the outer repository's view of the file.
      eq(vcssign.get_status(inner .. '/base.txt'), nil)
      eq(
        vcssign.get_status(outer .. '/base.txt').worktree,
        'modified',
        'the outer file is answered from the outer cache'
      )

      -- The cold call warmed the inner repository up.
      helpers.wait_for(function()
        return manager.get(inner) ~= nil
      end, 'the inner repository to be attached in the background')
      helpers.wait_for(function()
        local status = vcssign.get_status(inner .. '/base.txt')
        return status ~= nil and status.worktree == 'modified'
      end, 'the inner status to land')
    end),
  },
  {
    name = 'setup() merges options, defines the highlights and starts the autocmds',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      vcssign.setup({ log_level = 'info', sidebar = { width = 33 } })
      eq(config.get().sidebar.width, 33, 'the user option won')
      eq(config.get().sidebar.position, 'right', 'and the rest of the defaults survived')
      eq(config.get().log_level, 'info')
      eq(vim.fn.hlexists('VcssignSignModified'), 1, 'highlights are defined')
      -- Automatic attach is on now: opening a file in a repository attaches it
      -- without any command being run.
      local dir = repo_dir('cli-api-setup')
      edit_file(dir)
      helpers.wait_for(function()
        return manager.get_by_path(dir) ~= nil
      end, 'the autocmd to attach the buffer')
    end),
  },
  {
    name = 'completion offers the subcommands and stops after them',
    fn = guarded(function()
      reset()
      eq(cli.complete('', 'Vcssign '), cli.subcommands)
      eq(cli.complete('st', 'Vcssign st'), { 'stage' })
      eq(cli.complete('x', 'Vcssign x'), {})
      -- Arguments are paths; a `customlist` cannot complete those.
      eq(cli.complete('', 'Vcssign stage '), {})
      eq(cli.complete('ba', 'Vcssign stage ba'), {})
    end),
  },
  {
    name = 'plugin/vcssign.vim registers the command and it runs',
    fn = guarded(function()
      reset()
      vim.cmd('source ' .. vim.fn.fnameescape(helpers.plugin_root .. '/plugin/vcssign.vim'))
      eq(vim.fn.exists(':Vcssign'), 2, 'defined as a user command')

      local dir = repo_dir('cli-shim')
      edit_file(dir)
      -- `debug` deliberately attaches nothing, so this is also the proof that
      -- the shim reaches Lua at all: a bare session reports zero repositories.
      local seen = collect(function()
        vim.cmd('Vcssign debug')
      end)
      ok(seen[1].message:find('0 repositories', 1, true), seen[1].message)

      seen = collect(function()
        vim.cmd('Vcssign toggle')
        helpers.wait_for(function()
          return sidebar.open_count() == 1
        end, 'the sidebar to open')
      end)
      eq(#seen, 0, 'a successful toggle says nothing')
    end),
  },
}
