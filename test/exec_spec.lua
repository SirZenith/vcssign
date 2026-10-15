--- M2 acceptance for `lua/vcssign/exec.lua`, the process wrapper.
---
--- The important contract here is not the parsing helpers (those are trivial) but
--- the *context* the callback is delivered in: `vim.system`'s own callback is a
--- fast event context (measured), where buffer/window/message APIs raise E5560.
--- `exec.run` hops to the main loop so no layer above has to know that.
local helpers = require('helpers')

local config = require('vcssign.config')
local exec = require('vcssign.exec')

return {
  {
    name = 'the callback always runs on the main loop',
    fn = function()
      local fast, wrote = nil, false
      local err = helpers.wait(function(cb)
        exec.run({ 'git', '--version' }, { cwd = helpers.plugin_root }, function(e)
          fast = vim.in_fast_event()
          -- The practical consequence: a callback may touch buffer APIs.
          wrote = pcall(vim.api.nvim_buf_set_lines, 0, 0, -1, false, { 'x' })
          cb(e)
        end)
      end)
      eq(err, nil)
      eq(fast, false, 'the callback must not run in a fast event context')
      eq(wrote, true, 'buffer APIs must be usable inside the callback')
    end,
  },
  {
    name = 'a non-zero exit reports the first stderr line and keeps the result',
    fn = function()
      local res
      local err = helpers.wait(function(cb)
        exec.run({ 'git', 'status', '--definitely-not-an-option' }, { cwd = helpers.plugin_root }, function(e, r)
          res = r
          cb(e)
        end)
      end)
      ok(err ~= nil, 'a failing command must report an error')
      ok(err:match('^exit %d+: ') ~= nil, 'the error must name the exit code: ' .. tostring(err))
      ok(res ~= nil, 'the result is still passed for inspection')
      eq(res.code ~= 0, true)
      eq(res.cmd[1], 'git')
    end,
  },
  {
    name = 'a missing binary fails without raising',
    fn = function()
      local called, err = 0, nil
      -- `vim.system` raises ENOENT instead of calling back for a missing
      -- binary, so this must be caught inside `exec.run`.
      local raised = pcall(function()
        err = helpers.wait(function(cb)
          exec.run({ 'vcssign-does-not-exist-' .. tostring(vim.uv.hrtime()) }, { cwd = helpers.plugin_root }, function(e)
            called = called + 1
            cb(e)
          end)
        end)
      end)
      eq(raised, true, 'the failure must be delivered through the callback')
      eq(called, 1)
      ok(err ~= nil and err:match('spawn failed') ~= nil, 'got: ' .. tostring(err))
    end,
  },
  {
    name = 'the timeout kills the command and reports it once',
    fn = function()
      -- `git gc` on a big repository is slow enough to always lose a 1ms race;
      -- fall back to a sleeping shell if it somehow returns first.
      local sleep_cmd = exec.is_windows and { 'cmd', '/c', 'ping -n 5 127.0.0.1 >NUL' }
        or { 'sh', '-c', 'sleep 2' }
      local calls = 0
      local err = helpers.wait(function(cb)
        exec.run(sleep_cmd, { cwd = helpers.plugin_root, timeout = 1 }, function(e)
          calls = calls + 1
          cb(e)
        end)
      end)
      ok(err ~= nil and err:match('^timeout after 1ms') ~= nil, 'got: ' .. tostring(err))
      -- The killed process still exits later; its callback must be swallowed.
      vim.wait(300, function()
        return false
      end)
      eq(calls, 1, 'the callback must fire exactly once')
    end,
  },
  {
    name = 'a zero timeout means "no timeout"',
    fn = function()
      local err = helpers.wait(function(cb)
        exec.run({ 'git', '--version' }, { cwd = helpers.plugin_root, timeout = 0 }, cb)
      end)
      eq(err, nil)
    end,
  },
  {
    name = 'config.exec_timeout_ms is the default timeout',
    fn = function()
      local saved = vim.deepcopy(config.get())
      config.setup({ exec_timeout_ms = 1 })
      local sleep_cmd = exec.is_windows and { 'cmd', '/c', 'ping -n 5 127.0.0.1 >NUL' }
        or { 'sh', '-c', 'sleep 2' }
      local err = helpers.wait(function(cb)
        exec.run(sleep_cmd, { cwd = helpers.plugin_root }, cb)
      end)
      config.setup(saved)
      ok(err ~= nil and err:match('^timeout after 1ms') ~= nil, 'got: ' .. tostring(err))
    end,
  },
  {
    name = 'split_nul / split_lines / first_line',
    fn = function()
      eq(exec.split_nul('a\0b\0c\0'), { 'a', 'b', 'c' })
      eq(exec.split_nul(''), {})
      eq(exec.split_lines('a\nb\n\n'), { 'a', 'b' })
      eq(exec.split_lines('a\r\nb\r'), { 'a', 'b' })
      eq(exec.first_line('a\nb'), 'a')
      eq(exec.first_line('a\r\nb'), 'a')
      eq(exec.first_line(nil), '')
      eq(exec.first_line('  spaced  '), '  spaced')
    end,
  },
}
