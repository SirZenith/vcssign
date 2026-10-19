--- Async process execution (thin wrapper around `vim.system`).
---
--- Every VCS command in the plugin goes through here so that the environment
--- hardening and the error shape are defined in exactly one place.
--- See loop/archive/repo/2026-10-16T14-39-35-repo-runtime-and-refresh-pipeline.md §2.
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
---@field stdin? string|string[]     bytes piped to the child's stdin

-- Measured constraints for `stdin` (probe A):
--
-- * a **string** is written verbatim — no trailing newline is added, so a
--   patch fed to `git apply` must carry its own final `\n` (the missing byte
--   is exactly what makes git answer `error: corrupt patch at <stdin>:5`);
-- * a **string[]** gets one `\n` appended per element (`{'a','b'}` becomes
--   `"a\nb\n"`), which is convenient for line-oriented helpers;
-- * `text = true` only decodes *stdout* (CRLF -> LF).  It never touches the
--   stdin bytes, so callers must not rely on it to normalise the input.

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
--- The environment every child gets.
---
--- Force C locale so that command output is never localised into something our
--- parsers do not expect; on Windows stop MSYS2/Cygwin from rewriting arguments
--- that look like paths.  `opts.env` is merged over it.
---@param opts { env?: table<string,string> }
---@return table<string,string>
local function build_env(opts)
  local env = {
    LC_ALL = 'C',
    LANG = 'C',
    LANGUAGE = 'C',
  }
  if M.is_windows then
    env.MSYS = 'noglob'
    env.CYGWIN = 'noglob'
  end
  if opts.env then
    for k, v in pairs(opts.env) do
      env[k] = v
    end
  end
  return env
end

function M.run(cmd, opts, cb)
  local env = build_env(opts)
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

  local ok, started = pcall(
    vim.system,
    cmd,
    { cwd = opts.cwd, text = true, env = env, stdin = opts.stdin },
    function(res)
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
    end
  )
  proc = started

  if not ok then
    -- `vim.system` raises on spawn failure (e.g. the binary is missing)
    -- instead of invoking the exit callback.  `finish` closes the timeout
    -- timer, armed above.
    finish('spawn failed: ' .. tostring(started), nil)
    return
  end
end

---@class vcssign.StreamOpts
---@field cwd string
---@field env? table<string,string>
---@field on_stderr? fun(data: string)  called with every stderr chunk, if given

--- Spawn a long-lived child and stream its stdout (M7 P0-2).
---
--- Same environment hardening as `run`, but the other way round: the child
--- outlives the call, the caller consumes stdout as it arrives, and **there is
--- no timeout** — a reader that lives for the whole session has no single
--- deadline.  Whoever calls this owns the lifetime and the deadline (see
--- `vcs/git.lua`'s `CatFile`).
---
--- Both callbacks are invoked **on the main loop**: `vim.system`'s streaming
--- callbacks are fast events (same measurement as `run`), and a reader that
--- answers with file contents has to be able to reach buffer APIs.
---
--- Spawn failure returns `nil, err` instead of raising, because a missing
--- `cat-file` must degrade to the per-call command, not to an error in a
--- callback nobody sees.
---@param cmd string[]
---@param opts vcssign.StreamOpts
---@param on_stdout fun(err: string?, data: string?)
---@param on_exit fun(res: vcssign.ExecResult)
---@return vim.SystemObj? proc
---@return string? err
function M.stream(cmd, opts, on_stdout, on_exit)
  local ok, proc = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    -- `text` keeps the chunks as byte strings; a reader that delimits replies
    -- by a byte count (cat-file) must not have newlines split or joined for it.
    text = true,
    -- The whole point of a stream is that the caller can talk back: `write` is
    -- only available when stdin is a pipe opened for writing.
    stdin = true,
    env = build_env(opts),
    stdout = function(err, data)
      if err or not data or data == '' then
        return
      end
      vim.schedule(function()
        on_stdout(nil, data)
      end)
    end,
    stderr = function(err, data)
      -- `data` is nil (not merely empty) on the final call of some builds, so an
      -- emptiness check alone would still hand nil downstream.
      local sink = opts.on_stderr
      if err or not sink or not data or data == '' then
        return
      end
      vim.schedule(function()
        sink(data)
      end)
    end,
  }, function(res)
    vim.schedule(function()
      on_exit({
        cmd = cmd,
        code = res.code,
        signal = res.signal or 0,
        stdout = res.stdout or '',
        stderr = res.stderr or '',
      })
    end)
  end)
  if not ok then
    return nil, 'spawn failed: ' .. tostring(proc)
  end
  return proc
end

return M
