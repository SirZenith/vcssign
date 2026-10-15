--- Async process execution (thin wrapper around `vim.system`).
---
--- Every VCS command in the plugin goes through here so that the environment
--- hardening and the error shape are defined in exactly one place.
--- See impl/init/02-repo-runtime.md §2.
local config = require('vcssign.config')

local M = {}

---@type boolean
M.is_windows = vim.uv.os_uname().sysname == 'Windows_NT'

---@class vcssign.ExecResult
---@field cmd string[]
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string

---@class vcssign.ExecOpts
---@field cwd string                 working directory of the child process
---@field env? table<string,string>  extra env vars (merged over the defaults)
---@field timeout? integer           ms; defaults to `config.exec_timeout_ms`

--- First line of a (possibly multi-line, possibly CRLF) string.
---@param s string?
---@return string
function M.first_line(s)
  if not s or s == '' then
    return ''
  end
  return (vim.split(s:gsub('\r\n', '\n'), '\n', { plain = true })[1] or ''):gsub('%s+$', '')
end

--- Human readable one-liner for a failed command, used for `vim.notify`.
---@param res vcssign.ExecResult
---@return string
function M.error_message(res)
  local detail = M.first_line(res.stderr)
  if detail == '' then
    detail = M.first_line(res.stdout)
  end
  if detail == '' then
    detail = table.concat(res.cmd, ' ')
  end
  if res.signal ~= 0 then
    return string.format('signal %d: %s', res.signal, detail)
  end
  return string.format('exit %d: %s', res.code, detail)
end

--- Split NUL separated output, as produced by `git status --porcelain=v1 -z`.
--- Records are never legitimately empty, so empty chunks are dropped
--- (the trailing NUL would otherwise produce one).
---@param stdout string
---@return string[]
function M.split_nul(stdout)
  local out = {}
  for _, part in ipairs(vim.split(stdout, '\0', { plain = true })) do
    if part ~= '' then
      out[#out + 1] = part
    end
  end
  return out
end

--- Split newline separated output, dropping trailing blank lines.
---
--- A lone trailing `\r` (last line without a newline) is stripped too, so that
--- column-based parsers never see it as part of a path.
---@param stdout string
---@return string[]
function M.split_lines(stdout)
  local lines = vim.split(stdout:gsub('\r\n', '\n'), '\n', { plain = true })
  for i, line in ipairs(lines) do
    lines[i] = (line:gsub('\r$', ''))
  end
  while #lines > 0 and lines[#lines] == '' do
    table.remove(lines)
  end
  return lines
end

--- Run a command asynchronously.
---
--- `cb` is invoked exactly once, with either an error string or a result, and
--- always **on the main loop** — never in a fast event context.  That matters:
--- `vim.system`'s exit callback is itself a fast event (measured:
--- `vim.in_fast_event() == true`), where plain Lua, uv and *fast-safe* `vim.fn`
--- functions work but buffer/window/message APIs raise `E5560`.  Doing the hop
--- here means every layer above (adapters, `Repo`, actions, UI) can use any vim
--- API in its callbacks without knowing about libuv contexts.
---
--- A non-zero exit status is reported as an error; the result is still passed
--- so that callers may inspect partial output if they need to.
---@param cmd string[]
---@param opts vcssign.ExecOpts
---@param cb fun(err: string?, res: vcssign.ExecResult?)
function M.run(cmd, opts, cb)
  local env = {
    -- Force C locale so that command output is never localised into
    -- something our parsers do not expect.
    LC_ALL = 'C',
    LANG = 'C',
    LANGUAGE = 'C',
  }
  if M.is_windows then
    -- Stop MSYS2/Cygwin from rewriting arguments that look like paths.
    env.MSYS = 'noglob'
    env.CYGWIN = 'noglob'
  end
  if opts.env then
    for k, v in pairs(opts.env) do
      env[k] = v
    end
  end

  local finished = false
  ---@type uv.uv_timer_t?
  local timer

  ---@param err string?
  ---@param res vcssign.ExecResult?
  local function finish(err, res)
    if finished then
      return
    end
    finished = true
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
    if vim.in_fast_event() then
      vim.schedule(function()
        cb(err, res)
      end)
    else
      cb(err, res)
    end
  end

  ---@type vim.SystemObj?
  local proc

  local timeout = opts.timeout or config.get().exec_timeout_ms
  if timeout and timeout > 0 then
    -- Armed *before* the process is spawned, so that `finish` can always close
    -- it.  The exit callback is not guaranteed to arrive after this function
    -- returns (measured: a command that fails immediately, e.g. with an
    -- invalid cwd, calls back from inside `vim.system`), and a timer armed
    -- after that first `finish` had already run would sit armed until it fired
    -- — a live handle for the next 15s for a command that has long answered.
    timer = vim.uv.new_timer()
    if timer then
      timer:start(timeout, 0, function()
        -- `finish` nils the upvalue, so work on a local copy: this defensive
        -- branch would otherwise raise on a nil index instead of closing the
        -- handle.
        local t = timer
        if finished then
          if t and not t:is_closing() then
            t:stop()
            t:close()
          end
          return
        end
        if proc then
          pcall(function()
            proc:kill('sigterm')
          end)
        end
        finish(string.format('timeout after %dms: %s', timeout, table.concat(cmd, ' ')), nil)
      end)
    end
  end

  local ok, started = pcall(vim.system, cmd, { cwd = opts.cwd, text = true, env = env }, function(res)
    ---@type vcssign.ExecResult
    local result = {
      cmd = cmd,
      code = res.code,
      signal = res.signal or 0,
      stdout = res.stdout or '',
      stderr = res.stderr or '',
    }
    if res.code ~= 0 then
      finish(M.error_message(result), result)
    else
      finish(nil, result)
    end
  end)
  proc = started

  if not ok then
    -- `vim.system` raises on spawn failure (e.g. the binary is missing)
    -- instead of invoking the exit callback.  `finish` closes the timeout
    -- timer, armed above.
    finish('spawn failed: ' .. tostring(started), nil)
    return
  end
end

return M
