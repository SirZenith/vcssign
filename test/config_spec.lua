--- M1: configuration merge semantics.
--- See loop/archive/bootstrap/2026-10-16T20-52-42-master-plan.md §3.
local config = require('vcssign.config')

return {
  {
    name = 'lists replace wholesale instead of merging element-wise',
    fn = function()
      eq(config.merge({ systems = { 'git', 'svn' } }, { systems = { 'svn' } }).systems, { 'svn' })
    end,
  },
  {
    name = 'nested tables merge key by key',
    fn = function()
      eq(
        config.merge({ signs = { width = 40, position = 'right' } }, { signs = { width = 50 } }),
        { signs = { width = 50, position = 'right' } }
      )
    end,
  },
  {
    name = 'scalars and missing keys behave as expected',
    fn = function()
      eq(config.merge({ a = 1, b = 2 }, { a = 3 }), { a = 3, b = 2 })
      eq(config.merge({}, { c = 4 }), { c = 4 })
    end,
  },
  {
    name = 'merging never mutates the defaults table',
    fn = function()
      local defaults = { systems = { 'git', 'svn' }, signs = { width = 40 } }
      local before = vim.deepcopy(defaults)
      config.merge(defaults, { systems = { 'svn' }, signs = { width = 1 } })
      eq(defaults, before)
    end,
  },
  {
    name = 'nested lists replace at every level',
    fn = function()
      eq(
        config.merge({ a = { list = { 1, 2 } } }, { a = { list = { 3 } } }),
        { a = { list = { 3 } } }
      )
    end,
  },
  {
    name = 'an empty table merges like a dictionary, it does not wipe defaults',
    fn = function()
      eq(config.merge({ signs = { width = 40 } }, { signs = {} }), { signs = { width = 40 } })
    end,
  },
  {
    name = 'setup({}) restores the defaults',
    fn = function()
      config.setup({ systems = { 'svn' }, exec_timeout_ms = 1 })
      config.setup({})
      eq(config.get().systems, vim.deepcopy(config.defaults.systems))
      eq(config.get().exec_timeout_ms, config.defaults.exec_timeout_ms)
    end,
  },
}
