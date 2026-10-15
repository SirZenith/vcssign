--- Shared helpers for the headless specs.
---
--- Specs are plain Lua modules returning a list of `{ name, fn }` cases; a
--- failing assertion raises, and the runner (test/run.lua) turns that into a
--- `not ok` line.  See impl/init/05-testing-infra.md §3.
local M = {}

--- `vim.fs.normalize` is lexical and does not absolutise, so make sure the
--- script path is absolute before deriving the plugin root from it.
---@param path string
---@return string
local function abspath(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

local source = abspath(debug.getinfo(1, 'S').source:sub(2))
--- Plugin root, i.e. `.../vcssign`.
---@type string
M.plugin_root = vim.fs.dirname(vim.fs.dirname(source))

--- Absolute path of a fixture under `temp/`.
---@param name string
---@return string
function M.fixture(name)
  return vim.fs.normalize(vim.fs.joinpath(M.plugin_root, 'temp', name))
end

--- Run an async function and block until it reports back.
--- Returns whatever the callback was given: `err, ...`.
---@param fn fun(cb: fun(err: string?, ...))
---@param timeout? integer
function M.wait(fn, timeout)
  local finished, err, argc, values = false, nil, 0, {}
  fn(function(e, ...)
    err, argc, values = e, select('#', ...), { ... }
    finished = true
  end)
  if
    not vim.wait(timeout or 30000, function()
      return finished
    end, 5)
  then
    error('timeout: async operation never completed', 2)
  end
  return err, unpack(values, 1, argc)
end

---@param cond any
---@param msg? string
function M.ok(cond, msg)
  if not cond then
    error(msg or 'expected a truthy value', 2)
  end
end

---@param actual any
---@param expected any
---@param msg? string
function M.eq(actual, expected, msg)
  if not vim.deep_equal(actual, expected) then
    error(
      string.format(
        '%s\n  expected: %s\n    actual: %s',
        msg or 'values differ',
        vim.inspect(expected),
        vim.inspect(actual)
      ),
      2
    )
  end
end

--- Canonical, comparable view of a status list: `rel_path:index/worktree`
--- strings, sorted by `rel_path` so expectations read in path order.
---@param entries vcssign.StatusEntry[]
---@return string[]
function M.status_set(entries)
  local rows = {}
  for _, entry in ipairs(entries) do
    rows[#rows + 1] = {
      rel_path = entry.rel_path,
      text = string.format('%s:%s/%s', entry.rel_path, entry.status.index or '-', entry.status.worktree or '-'),
    }
  end
  table.sort(rows, function(a, b)
    return a.rel_path < b.rel_path
  end)
  local out = {}
  for i, row in ipairs(rows) do
    out[i] = row.text
  end
  return out
end

---@param entries vcssign.StatusEntry[]
---@param rel_path string
---@return vcssign.StatusEntry?
function M.entry(entries, rel_path)
  for _, entry in ipairs(entries) do
    if entry.rel_path == rel_path then
      return entry
    end
  end
  return nil
end

-- ▏ scratch fixtures ──────────────────────────────────────────────────────────
---
--- Specs that need a *mutable* repository (`git add`, file writes, a deleted
--- marker) build one here instead of touching the shared `temp/` fixtures, whose
--- exact status matrix the M1 specs assert on.

---@type table<string, true>
M._scratch_dirs = {}

--- A fresh, empty directory under `temp/_spec/`, removed by `cleanup()`.
---@param name string
---@return string
function M.scratch_dir(name)
  local dir = vim.fs.normalize(vim.fs.joinpath(M.plugin_root, 'temp', '_spec', name))
  vim.fn.delete(dir, 'rf')
  vim.fn.mkdir(dir, 'p')
  M._scratch_dirs[dir] = true
  return dir
end

--- Remove every scratch directory created during the run, plus their parent.
function M.cleanup()
  -- Deepest first, so nested directories go before their parents.
  local dirs = vim.tbl_keys(M._scratch_dirs)
  table.sort(dirs, function(a, b)
    return #a > #b
  end)
  for _, dir in ipairs(dirs) do
    vim.fn.delete(dir, 'rf')
  end
  M._scratch_dirs = {}
  vim.fn.delete(vim.fs.joinpath(M.plugin_root, 'temp', '_spec'), 'rf')
end

--- Write `content` to `path`, creating parent directories.
---@param path string
---@param content string
function M.write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(vim.split(content, '\n', { plain = true, trimempty = true }), path)
end

--- Run a command to completion; raises with its output when it fails.
---@param cmd string[]
---@param cwd? string
---@return string combined stdout and stderr
function M.sh(cmd, cwd)
  local res = vim.system(cmd, { cwd = cwd, text = true }):wait()
  local out = (res.stdout or '') .. (res.stderr or '')
  if res.code ~= 0 then
    error(string.format('command failed (%d): %s\n%s', res.code, table.concat(cmd, ' '), out), 2)
  end
  return out
end

--- A throwaway git repository: one commit, a clean `base.txt` and `sub/nested.txt`.
---@param name string
---@return string dir
function M.git_repo(name)
  local dir = M.scratch_dir(name)
  M.sh({ 'git', 'init', '-q', '-b', 'main', dir })
  M.sh({ 'git', '-C', dir, 'config', 'user.email', 't@t' })
  M.sh({ 'git', '-C', dir, 'config', 'user.name', 't' })
  M.write(dir .. '/base.txt', 'base\n')
  M.write(dir .. '/sub/nested.txt', 'nested\n')
  M.sh({ 'git', '-C', dir, 'add', '-A' })
  M.sh({ 'git', '-C', dir, 'commit', '-qm', 'init' })
  return dir
end

--- `file://` URL of the svn server fixture (`temp/svn-server`).
---@return string
function M.svn_url()
  return 'file:///' .. M.fixture('svn-server')
end

--- A throwaway git repository plus a linked worktree of it.
---
--- In a worktree `.git` is a *file* pointing at `<main>/.git/worktrees/<name>`,
--- so the index lives outside the worktree — the case a keyfile-only watcher
--- cannot see.
---@param name string
---@return string worktree
---@return string main_repo
function M.git_worktree(name)
  local main_repo = M.git_repo(name .. '-main')
  -- `git worktree add` accepts an existing *empty* directory.
  local worktree = M.scratch_dir(name)
  M.sh({ 'git', '-C', main_repo, 'worktree', 'add', '-q', '-b', 'wt-' .. name, worktree })
  return worktree, main_repo
end

--- A throwaway svn working copy of the fixture's `trunk`.
---@param name string
---@return string dir
function M.svn_checkout(name)
  local dir = M.scratch_dir(name)
  M.sh({ 'svn', 'co', '-q', M.svn_url() .. '/trunk', dir })
  return dir
end

--- A throwaway svn repository *and* a working copy of it, both under
--- `temp/_spec/`.
---
--- `svn_checkout` shares one server on purpose (`temp/svn-server`, several
--- specs assert its exact status matrix), which is why a spec that *writes* to
--- the repository — a commit — needs a server nobody else looks at.
---@param name string
---@return string dir  working copy
---@return string url  `file://` url of the server
function M.svn_repo(name)
  local server = M.scratch_dir(name .. '-server')
  local dir = M.scratch_dir(name .. '-wc')
  M.sh({ 'svnadmin', 'create', server })
  local url = 'file:///' .. server
  -- Seed one revision, so the working copy starts with something to change
  -- (`svn commit` of an added-only tree would work too, but a base revision
  -- makes the diff and status assertions simpler).
  local seed = M.scratch_dir(name .. '-seed')
  M.write(seed .. '/base.txt', 'base\n')
  M.write(seed .. '/sub/nested.txt', 'nested\n')
  M.sh({ 'svn', 'import', '-q', '-m', 'init', seed, url .. '/trunk' })
  M.sh({ 'svn', 'co', '-q', url .. '/trunk', dir })
  return dir, url
end

-- ▏ runtime helpers ───────────────────────────────────────────────────────────

--- Block until `pred()` is true.
---@param pred fun(): boolean
---@param msg string
---@param timeout? integer
function M.wait_for(pred, msg, timeout)
  if not vim.wait(timeout or 5000, pred, 10) then
    error('timeout waiting for: ' .. msg, 2)
  end
end

--- Live libuv handles of `kind` (`fs_event`, `timer`, ...), for leak assertions.
---@param kind string
---@return integer
function M.uv_count(kind)
  local n = 0
  vim.uv.walk(function(handle)
    if handle:get_type() == kind and not handle:is_closing() then
      n = n + 1
    end
  end)
  return n
end

---@class vcssign.CapturedNotify
---@field message string
---@field level integer

--- Run `fn` with `vim.notify` stubbed out and report what it sent.  Levels are
--- kept because "is this INFO or ERROR" is part of the behaviour under test.
---
--- The stub also swallows messages the plugin defers through `vim.schedule`
--- (`log` routes everything that way), which is why the drain below happens
--- *before* `vim.notify` is restored.
---
--- `is_done` is for the answers that arrive asynchronously (every VCS command
--- does): the case waits for its notification while the stub is still in place,
--- which is what makes "the action reported X" assertable at all.
---@param fn function
---@param is_done? fun(seen: vcssign.CapturedNotify[]): boolean
---@return vcssign.CapturedNotify[]
function M.capture_notify(fn, is_done)
  local real = vim.notify
  local captured = {} ---@type vcssign.CapturedNotify[]
  vim.notify = function(message, level)
    captured[#captured + 1] = { message = message, level = level or vim.log.levels.INFO }
  end
  local ok, err = pcall(fn)
  if ok then
    if is_done then
      if not vim.wait(5000, function()
        return is_done(captured)
      end, 10) then
        vim.notify = real
        error('timeout waiting for a notification', 2)
      end
    else
      vim.wait(50, function()
        return false
      end)
    end
  end
  vim.notify = real
  if not ok then
    error(err, 0)
  end
  return captured
end

--- One rendered screen row of `win`, as a string.
---
--- Reads the real screen grid, so it asserts what a user sees — signs and all —
--- rather than what the buffer happens to contain.  The row starts at the
--- window's left edge, i.e. the first cell is the vertical separator.
---@param win integer
---@param row integer  1-based *screen* row
---@return string
function M.screen_line(win, row)
  vim.cmd('redraw')
  local col = vim.api.nvim_win_get_position(win)[2]
  local cells = {}
  for i = 0, vim.api.nvim_win_get_width(win) do
    cells[#cells + 1] = vim.fn.screenstring(row, col + i)
  end
  return table.concat(cells)
end

--- Screen row of line `line` (1-based, buffer-relative) inside `win`.
---@param win integer
---@param line integer
---@return string
function M.screen_line_at(win, line)
  return M.screen_line(win, vim.api.nvim_win_get_position(win)[1] + line)
end

--- Attach `ref` to the repository containing `path`, run `fn(repo)`, then always
--- release the reference again — including when the body raises.
---@param ref string
---@param path string
---@param fn fun(repo: vcssign.Repo)
function M.with_repo(ref, path, fn)
  local manager = require('vcssign.repo_manager')
  local err, repo = M.wait(function(cb)
    manager.attach(ref, path, cb)
  end)
  if not repo then
    error('attach failed: ' .. tostring(err), 2)
  end
  local ok, inner = pcall(fn, repo)
  manager.detach(ref)
  if not ok then
    error(inner, 2)
  end
end

return M
