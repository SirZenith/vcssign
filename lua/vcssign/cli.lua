--- The `:Vcssign` command family.
---
--- One dispatch table, one completion function, and one place that answers
--- "which repository does the user mean" — the same question the public API in
--- `vcssign/init.lua` asks, which is why both go through
--- `repo_manager.ensure()`.
--- See impl/init/04-commands-actions.md §3.
local actions = require('vcssign.actions')
local attach = require('vcssign.attach')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local registry = require('vcssign.vcs')

local M = {}

--- Subcommands, in the order `:Vcssign` lists and completes them.
---@type string[]
M.subcommands = {
  'toggle',
  'refresh',
  'stage_hunk',
  'undo_stage_hunk',
  'reset_hunk',
  'stage_buffer',
  'reset_buffer',
  'preview_hunk',
  'diff',
  'diffthis',
  'blame_line',
  'commit',
  'debug',
}

--- Where a command with no path argument points: the current buffer's file,
--- else the cwd.
---@return string
local function current_path()
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name ~= '' then
    return name
  end
  return vim.uv.cwd() or '.'
end

--- Tell the user that a path belongs to no repository.
---
--- Shared with the public API (`vcssign/init.lua`), so a path-less
--- `require('vcssign').refresh()` and `:Vcssign refresh` answer the same way.
---@param path string
---@param err string?
function M.report_no_repo(path, err)
  if err and err:find('attach cancelled', 1, true) then
    -- Superseded by a newer command: the caller is gone, so a message would
    -- only be noise about work nobody is waiting for.
    return
  end
  local message = string.format('no repository found for %s', path)
  -- "No repository" is an answer, not a failure (most directories are not
  -- repositories, 04 §6.1); anything else — a missing binary, a permission
  -- problem, a timeout — is environmental and worth an error.
  if err == nil or registry.is_definitive_negative(err) then
    -- Not an error: most directories are not repositories (04 §6).
    log.notify(message)
  else
    log.notify_error(message .. ': ' .. err)
  end
end

--- Run `fn(repo)` for the repository containing `path`, attaching it first when
--- nothing has attached it yet: a command has to work as the very first thing
--- the user types.
---@param path string  never nil: `current_path()` is how a command with no
---        argument resolves one
---@param fn fun(repo: vcssign.Repo)
local function with_repo(path, fn)
  manager.ensure(path, function(err, repo)
    if not repo then
      return M.report_no_repo(path, err)
    end
    fn(repo)
  end)
end

---@type table<string, fun(path: string): nil>
local commands = {}

--- The loaded buffer showing `path`, when there is one.
---@param path string
---@return integer?
local function buffer_for(path)
  local bufnr = vim.fn.bufnr(path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  return bufnr
end

--- Attach and re-render the buffer showing `path`, when there is one.
---
--- `:Vcssign refresh` is how a file gets its signs when `setup()` — and with
--- it the autocmds — has not run, so the buffer is attached here rather than
--- only refreshed.
---@param path string
local function refresh_buffer(path)
  local bufnr = buffer_for(path)
  if not bufnr then
    return
  end
  local st = attach.state(bufnr)
  if st and st.attached then
    attach.refresh(bufnr)
  else
    attach.attach(bufnr)
  end
end

---@param path string
commands.refresh = function(path)
  local target = path or current_path()
  refresh_buffer(target)
  with_repo(target, function(repo)
    repo:refresh_now()
  end)
end

--- Turn the signs of one buffer on or off.
---
--- `path` is optional: with it, the buffer showing that file; without it, the
--- current buffer.
---@param path string
commands.toggle = function(path)
  local bufnr = path and buffer_for(path) or vim.api.nvim_get_current_buf()
  if not bufnr then
    return log.notify_error(string.format('%s is not open in a buffer', path))
  end
  if attach.toggle(bufnr) == nil then
    local name = vim.api.nvim_buf_get_name(bufnr)
    log.notify_error(
      string.format('cannot toggle signs for %s', name ~= '' and name or 'this buffer')
    )
  end
end

-- The file-level commands attach first (so they work before any buffer did)
-- but hand the *original* argument to the action: `actions` decides which file
-- "no argument" means (the current buffer's file), and passing the resolved
-- root instead would turn `diff` into "diff the whole repository".
for _, name in ipairs({ 'diff', 'commit' }) do
  commands[name] = function(path)
    local target = path
    with_repo(path or current_path(), function()
      actions[name](target)
    end)
  end
end

-- The hunk commands act on a *buffer*: the hunk is picked with the cursor and
-- the patch is built from the buffer's text, which may hold changes the file on
-- disk does not have.  So their argument is a file that has to be open, and one
-- that is not open is refused rather than guessed at.
for _, name in ipairs({
  'stage_hunk',
  'undo_stage_hunk',
  'reset_hunk',
  'stage_buffer',
  'reset_buffer',
  'preview_hunk',
}) do
  commands[name] = function(path)
    local target = path or current_path()
    local bufnr = buffer_for(target)
    if bufnr == nil then
      return log.notify_error(string.format('%s is not open in a buffer', target))
    end
    actions[name](target, { bufnr = bufnr })
  end
end

--- The view commands describe the *current buffer's* file, so their argument is
--- a revision (`:Vcssign diffthis HEAD~1`), not a path: a diff against a named
--- revision is built from the buffer's own text, and blame is about the line the
--- cursor is on.
---@param rev string|nil
commands.diffthis = function(rev)
  actions.diffthis(nil, rev and { rev = rev } or nil)
end

commands.blame_line = function()
  actions.blame_line(nil, nil)
end

---@return string
local function debug_report()
  local repos = manager.all()
  table.sort(repos, function(a, b)
    return a.root < b.root
  end)
  local lines = {
    string.format('%d repositories', #repos),
    string.format('%d buffers with signs', attach.count()),
  }
  for _, repo in ipairs(repos) do
    local flags = {}
    if repo.is_deleted then
      flags[#flags + 1] = 'deleted'
    end
    if repo.is_updating then
      flags[#flags + 1] = 'updating'
    end
    if repo.has_pending then
      flags[#flags + 1] = 'pending'
    end
    if repo.is_dirty then
      flags[#flags + 1] = 'dirty'
    end
    lines[#lines + 1] = string.format(
      '  %s %s  refs=%d watchers=%d loaded=%s %s%s',
      repo.system.name,
      repo.root,
      vim.tbl_count(repo.refs),
      vim.tbl_count(repo.fs_handles),
      tostring(repo.has_loaded),
      #flags > 0 and table.concat(flags, '+') or 'clean',
      repo.last_error and ('  last_error=' .. repo.last_error) or ''
    )
  end
  -- The watcher count above is per repository; this is the whole event loop,
  -- which is what a leak (or a forgotten `close()`) shows up in.
  local handles = 0
  vim.uv.walk(function(handle)
    if handle:get_type() == 'fs_event' and not handle:is_closing() then
      handles = handles + 1
    end
  end)
  lines[#lines + 1] = string.format('  %d fs_event handles in the loop', handles)
  return table.concat(lines, '\n')
end

commands.debug = function()
  log.notify(debug_report())
end

--- Dispatch one `:Vcssign` invocation.
---@param args string[]  `params.fargs` from the command
function M.run(args)
  args = args or {}
  local name = args[1] or 'refresh'
  local handler = commands[name]
  if not handler then
    return log.notify_error(
      string.format('unknown command %q; try one of: %s', name, table.concat(M.subcommands, ', '))
    )
  end
  -- `:Vcssign` is declared with `-nargs=*`, so a path with a space arrives as
  -- several words (Vim splits on whitespace unless the user escapes): put the
  -- rest back together rather than silently using the first word.  Joining with
  -- a single space means *runs* of spaces collapse, so a path with two adjacent
  -- spaces has to be escaped (`:Vcssign stage 'a  b.txt'`).
  local rest = vim.list_slice(args, 2)
  handler(#rest > 0 and table.concat(rest, ' ') or nil)
end

--- Completion for `:Vcssign` (a `customlist` function).
---
--- Only the subcommand is completed: `-complete=customlist` cannot also do file
--- completion, and a wrong path argument is a `no repository found` message
--- rather than a disaster.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local words = vim.split(vim.trim(cmdline), '%s+', { trimempty = true })
  local trailing_space = cmdline:match('%s$') ~= nil
  -- `words[1]` is the command name itself, so one word (plus nothing being
  -- typed) or two words (the second one being typed) is still the subcommand.
  -- After `:Vcssign stage ` the argument is a path, which is out of scope here.
  if #words > 2 or (#words == 2 and trailing_space) then
    return {}
  end
  local matches = {}
  for _, name in ipairs(M.subcommands) do
    if vim.startswith(name, arglead) then
      matches[#matches + 1] = name
    end
  end
  return matches
end

--- Exposed for the specs (the `debug` subcommand's body).
M._debug_report = debug_report

return M
