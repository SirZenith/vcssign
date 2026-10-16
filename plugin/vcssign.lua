--- vcssign: file status signs for git and svn.
---
--- Thin on purpose: the command is registered here and nothing else is loaded
--- until it is first used, so `setup()` stays optional (every layer has
--- defaults) and opening a file stays cheap until a repository is touched.
--- See loop/archive/commands/2026-10-16T17-33-54-commands-and-actions.md §1
--- (registration) and §4 (what `setup()` turns on).

if vim.g.loaded_vcssign then
  return
end
vim.g.loaded_vcssign = 1

vim.api.nvim_create_user_command('Vcssign', function(params)
  require('vcssign.cli').run(params.fargs)
end, {
  nargs = '*',
  complete = function(arglead, cmdline)
    return require('vcssign.cli').complete(arglead, cmdline)
  end,
  desc = 'vcssign: file status signs (toggle, refresh, diff, commit, debug)',
})
