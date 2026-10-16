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
        exec.run(
          { 'git', 'status', '--definitely-not-an-option' },
          { cwd = helpers.plugin_root },
          function(e, r)
            res = r
            cb(e)
          end
        )
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
          exec.run(
            { 'vcssign-does-not-exist-' .. tostring(vim.uv.hrtime()) },
            { cwd = helpers.plugin_root },
            function(e)
              called = called + 1
              cb(e)
            end
          )
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
    name = 'no run leaves a timeout timer armed',
    fn = function()
      -- The timeout timer is armed *before* the process is spawned, so that
      -- `finish` can always close it.  The other order leaks an armed handle
      -- whenever the exit callback arrives before the timer exists (measured
      -- with a command that fails immediately) — and the leak is only visible
      -- as a live `uv_timer_t`, which is what this asserts, on each of the four
      -- ways a run can end.
      local function timers()
        return helpers.uv_count('timer')
      end
      ---@param cmd string[]
      ---@param opts table
      local function run(cmd, opts)
        local before = timers()
        helpers.wait(function(cb)
          exec.run(cmd, opts, cb)
        end)
        eq(timers(), before, 'no timer left for: ' .. table.concat(cmd, ' '))
      end

      run({ 'git', '--version' }, { cwd = helpers.plugin_root })
      -- spawn failure (the cwd does not exist) …
      run({ 'git', '--version' }, { cwd = helpers.plugin_root .. '/no-such-directory' })
      -- … a missing binary (vim.system raises) …
      run({ 'vcssign-not-a-binary' }, { cwd = helpers.plugin_root })
      -- … and a command the timeout has to kill.
      local sleep_cmd = vim.fn.executable('sleep') == 1 and { 'sleep', '5' }
        or { 'cmd', '/c', 'ping -n 6 127.0.0.1 > nul' }
      local saved = config.get().exec_timeout_ms
      config.setup({ exec_timeout_ms = 1 })
      run(sleep_cmd, { cwd = helpers.plugin_root })
      config.setup({ exec_timeout_ms = saved })
    end,
  },
  {
    name = 'a synchronous exit callback still leaves no timer armed',
    fn = function()
      -- This is the shape that actually bit us: `vim.system`'s exit callback
      -- can run *before* `exec.run` returns (seen with a command that fails
      -- immediately), and a timeout timer armed after the spawn is then never
      -- closed — a live, armed `uv_timer_t` for the whole timeout window.
      --
      -- The stub hands the callback over synchronously, which is exactly that
      -- situation, so the invariant "the timer exists before the spawn can call
      -- back" is what gets pinned here (the four ordinary endings are covered by
      -- the case above).
      local real_system = vim.system
      local before = helpers.uv_count('timer')
      vim.system = function(cmd, opts, on_exit)
        local proc = real_system(cmd, opts, on_exit)
        if on_exit then
          on_exit({ code = 0, signal = 0, stdout = 'stub', stderr = '' })
        end
        return proc
      end
      -- (`called`, not `ok`: `ok` is the assertion helper.)
      local called, err = pcall(helpers.wait, function(cb)
        exec.run({ 'git', '--version' }, { cwd = helpers.plugin_root }, cb)
      end)
      vim.system = real_system
      ok(called, tostring(err))
      eq(helpers.uv_count('timer'), before, 'no armed timeout timer survived')
    end,
  },
  {
    name = 'a string stdin is written verbatim, with no trailing newline added',
    fn = function()
      -- Measured (probe A): a `string` is handed to the pipe byte for byte;
      -- `vim.system` does not append a newline for you.  A unified patch must
      -- therefore carry its own final `\n` (probe B4: without it, `git apply`
      -- answers `error: corrupt patch`).
      local res
      local err = helpers.wait(function(cb)
        exec.run({ 'cat' }, { cwd = helpers.plugin_root, stdin = 'a\nb' }, function(e, r)
          res = r
          cb(e)
        end)
      end)
      eq(err, nil)
      eq(res.stdout, 'a\nb', 'the bytes must arrive exactly as given')
    end,
  },
  {
    name = 'a string[] stdin gets a newline appended to each element',
    fn = function()
      -- The array form is line-oriented: each element becomes one line, so the
      -- caller does not have to spell the separators (probe A).
      local res
      local err = helpers.wait(function(cb)
        exec.run({ 'cat' }, { cwd = helpers.plugin_root, stdin = { 'a', 'b' } }, function(e, r)
          res = r
          cb(e)
        end)
      end)
      eq(err, nil)
      eq(res.stdout, 'a\nb\n', 'each element is its own line')
    end,
  },
  {
    name = 'a large stdin round-trips through the pipe untruncated',
    fn = function()
      -- Past every OS pipe buffer, so this only holds if writing stdin is
      -- coupled to reading stdout rather than racing the process.
      local line = string.rep('x', 79)
      local lines = {}
      for _ = 1, 3400 do
        lines[#lines + 1] = line
      end
      local payload = table.concat(lines, '\n') .. '\n'
      ok(#payload >= 256 * 1024, 'the payload must be at least 256 KiB')

      local res
      local err = helpers.wait(function(cb)
        exec.run({ 'cat' }, { cwd = helpers.plugin_root, stdin = payload }, function(e, r)
          res = r
          cb(e)
        end)
      end)
      eq(err, nil)
      eq(#res.stdout, #payload, 'the whole payload must come back')
      eq(res.stdout, payload)
    end,
  },
  {
    name = 'a timed-out run with stdin leaves no timer handle',
    fn = function()
      -- The stdin write must not keep the timeout timer alive after the kill:
      -- a live `uv_timer_t` is the leak shape the rest of this file pins.
      local before = helpers.uv_count('timer')
      local sleep_cmd = exec.is_windows and { 'cmd', '/c', 'ping -n 5 127.0.0.1 >NUL' }
        or { 'sh', '-c', 'sleep 2' }
      local err = helpers.wait(function(cb)
        exec.run(sleep_cmd, { cwd = helpers.plugin_root, timeout = 1, stdin = 'payload\n' }, cb)
      end)
      ok(err ~= nil and err:match('^timeout after 1ms') ~= nil, 'got: ' .. tostring(err))
      eq(helpers.uv_count('timer'), before, 'no timeout timer may survive the kill')
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
