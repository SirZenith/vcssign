--- `:Vcssign` command specs.
---
--- The command layer is where "which repository does the user mean" gets
--- answered, so the cases below are mostly about *targeting*: the current
--- buffer's file, the path argument, and what the user is told when none of
--- them apply.
--- See impl/init/04-commands-actions.md §3, §6 and
--- impl/init/07-signs-in-signcolumn.md §6.
local attach = require('vcssign.attach')
local autocmds = require('vcssign.autocmds')
local cli = require('vcssign.cli')
local config = require('vcssign.config')
local helpers = require('helpers')
local manager = require('vcssign.repo_manager')
local signs = require('vcssign.signs')

--- The configuration as it was when this file started: one case calls
--- `setup()`, and every later case would otherwise run with its options.
local DEFAULTS = vim.deepcopy(config.get())

--- Back to a clean editor between cases.  `cd` matters: several cases move the
--- cwd on purpose, and relative paths mean different things afterwards.
local function reset()
  attach.forget_all()
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
      local dir = repo_dir('cli-refresh')
      edit_file(dir)
      eq(manager.count(), 0, 'nothing is tracked yet')

      cli.run({ 'refresh', dir .. '/base.txt' })
      -- `ensure` has to detect and attach it first: `:Vcssign refresh` in a
      -- fresh session is the first thing that happens.
      helpers.wait_for(function()
        return manager.count() == 1
      end, 'the repository to attach')
      ok(manager.get_by_path(dir .. '/base.txt') ~= nil, 'the repository is tracked now')
      -- Two asynchronous chains are running: the repository's detection (which
      -- the wait above settles) and the buffer's own attach, which binds the
      -- buffer's reference when *its* detection answers.
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached
      end, 'the buffer to attach')

      -- No argument at all means the current buffer's file (04 §3).
      cli.run({})
      -- D29: the command pins *the repository* for the session — one reference
      -- per repository, no matter how many commands (or how many files) name it.
      -- Two holders here: the buffer (`refresh` attaches it whether or not the
      -- autocmds are on) and the command reference D29 adds.
      local held = manager.ref_count(dir)
      eq(held, 2, 'the buffer and the command hold it')
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
    name = 'outside every repository it says so, at INFO level',
    fn = guarded(function()
      reset()
      local elsewhere = vim.fn.tempname()
      vim.fn.mkdir(elsewhere, 'p')
      vim.cmd('cd ' .. vim.fn.fnameescape(elsewhere))
      vim.cmd('enew')

      local seen = collect(function()
        cli.run({ 'refresh' })
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].level, vim.log.levels.INFO, 'not an error: most directories are not repositories')
      ok(seen[1].message:find('no repository found', 1, true), seen[1].message)
      ok(
        seen[1].message:find(elsewhere, 1, true),
        'and it names the path it looked at: ' .. seen[1].message
      )
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'debug reports the repositories and the watch handles',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-debug')
      edit_file(dir)
      cli.run({ 'refresh' })
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

      edit_file(outer)
      cli.run({ 'refresh', outer .. '/base.txt' })
      helpers.wait_for(function()
        return manager.get(outer) ~= nil
      end, 'the outer repository to attach')
      eq(manager.get(outer).root:lower(), outer:lower())

      -- Now a file from the inner repository: the deepest repository wins, or
      -- every action behind the command would be addressing the outer tree.
      cli.run({ 'refresh', inner .. '/base.txt' })
      helpers.wait_for(function()
        return manager.get(inner) ~= nil
      end, 'the inner repository to attach')
      eq(manager.count(), 2)
      eq(manager.get(inner).root:lower(), inner:lower(), 'the inner repository is its own')
      eq(manager.get_by_path(inner .. '/base.txt').root:lower(), inner:lower())
    end),
  },
  {
    name = 'the public API refreshes without a prior attach',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      local dir = repo_dir('cli-api-refresh')
      eq(manager.count(), 0)

      vcssign.refresh(dir .. '/base.txt')
      helpers.wait_for(function()
        return manager.get_by_path(dir) ~= nil
      end, 'the repository to attach')
      local repo = manager.get_by_path(dir)
      ok(repo ~= nil, 'and the repository is attached')

      -- An external change, picked up by an explicit refresh.  `Repo` does
      -- not cache status any more (D38), so what is observable is the refresh
      -- pass itself.
      local passes = helpers.count_refreshes(repo)
      helpers.write(dir .. '/api.txt', 'untracked\n')
      vcssign.refresh(dir .. '/base.txt')
      helpers.wait_for(function()
        return passes() > 0
      end, 'the refresh to land')
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
        vcssign.refresh()
      end, function(s)
        return #s > 0
      end)
      -- INFO with the path, exactly like `:Vcssign refresh` (one implementation
      -- in `cli.report_no_repo`), not a bare unclassified message.
      eq(seen[1].level, vim.log.levels.INFO)
      ok(seen[1].message:find('no repository found', 1, true), seen[1].message)
      ok(seen[1].message:find(elsewhere, 1, true), seen[1].message)
      vim.fn.delete(elsewhere, 'rf')
    end),
  },
  {
    name = 'toggle turns the signs of one buffer off and on',
    fn = guarded(function()
      reset()
      local dir = repo_dir('cli-toggle')
      edit_file(dir)
      local bufnr = vim.fn.bufnr(dir .. '/base.txt')
      cli.run({ 'refresh' })
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.attached and st.buf_text ~= nil
      end, 'the buffer to be attached')
      local repo = manager.get_by_path(dir)
      local refs = manager.ref_count(repo.root)
      ok(signs.sign_count(bufnr) > 0, 'signs are up to start with')

      local seen = collect(function()
        cli.run({ 'toggle' })
      end)
      eq(#seen, 0, 'toggling off is not an error')
      eq(attach.state(bufnr).shown, false)
      eq(signs.sign_count(bufnr), 0, 'and the signs are gone')

      -- Off is a state, not a teardown: the reference and the detection cache
      -- stay, so switching back on redraws instead of re-probing the VCS.
      eq(manager.ref_count(repo.root), refs, 'the reference is untouched')

      collect(function()
        cli.run({ 'toggle' })
      end)
      -- Back on, the baseline is re-read (`mark_dirty` returned early while the
      -- switch was off), so the signs arrive with that answer.
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.shown == true and signs.sign_count(bufnr) > 0
      end, 'the signs to come back')
      eq(attach.state(bufnr).shown, true)
      ok(signs.sign_count(bufnr) > 0, 'and the signs come back')
    end),
  },
  {
    name = 'toggle says so when the buffer has no signs to switch',
    fn = guarded(function()
      reset()
      -- Unnamed buffer, nothing to attach to.
      vim.cmd('enew')
      local seen = collect(function()
        cli.run({ 'toggle' })
      end)
      eq(seen[1].level, vim.log.levels.ERROR, seen[1].message)
      ok(seen[1].message:find('cannot toggle signs', 1, true), seen[1].message)
    end),
  },
  {
    name = 'setup() merges options and starts the autocmds',
    fn = guarded(function()
      reset()
      local vcssign = require('vcssign')
      vcssign.setup({ log_level = 'info', signs = { add = { text = '#' } } })
      eq(config.get().signs.add.text, '#', 'the user option won')
      eq(config.get().signs.change.text, '▎', 'and the rest of the defaults survived')
      eq(config.get().log_level, 'info')
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
      eq(cli.complete('t', 'Vcssign t'), { 'toggle' }, 'a unique prefix resolves to one name')
      eq(
        cli.complete('r', 'Vcssign r'),
        { 'refresh', 'reset_hunk', 'reset_buffer' },
        'every name the prefix could mean, in the order they are listed'
      )
      eq(cli.complete('x', 'Vcssign x'), {})
      -- Arguments are paths; a `customlist` cannot complete those.
      eq(cli.complete('', 'Vcssign refresh '), {})
      eq(cli.complete('ba', 'Vcssign refresh ba'), {})
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
        vim.cmd('Vcssign refresh')
      end)
      eq(#seen, 0, 'a successful refresh says nothing')
    end),
  },
}
