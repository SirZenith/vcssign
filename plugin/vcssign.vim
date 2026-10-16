" vcssign: file status signs for git and svn.
"
" Thin on purpose (impl/init/04-commands-actions.md §1): the command is
" registered here, and the Lua module tree is only loaded when it is first
" used.  `setup()` stays optional — every layer has defaults — but it is what
" turns on automatic attach (see impl/init/04-commands-actions.md §4).

if exists('g:loaded_vcssign')
  finish
endif
let g:loaded_vcssign = 1

lua << EOF
vim.api.nvim_create_user_command('Vcssign', function(params)
  require('vcssign.cli').run(params.fargs)
end, {
  nargs = '*',
  complete = function(arglead, cmdline)
    return require('vcssign.cli').complete(arglead, cmdline)
  end,
  desc = 'vcssign: file status signs (refresh, diff, commit, debug)',
})
EOF
