--- git adapter.
---
--- See impl/init/01-vcs-adapter.md §4.  Three things differ from the
--- vcs-helper.nvim reference implementation on purpose:
---   1. root detection asks git itself (worktrees and submodules, where `.git`
---      is a *file*, cannot be found by a pure marker scan);
---   2. status is read through `--porcelain=v1 -z`, so paths containing spaces,
---      quotes or non-ASCII bytes need no quoting/escaping handling at all;
---   3. every path the adapter reports is anchored at the repo root, never at
---      the editor's cwd.
local exec = require('vcssign.exec')
local base = require('vcssign.vcs.base')

local M = {}

M.name = 'git'
M.keyfile = '.git'
M.capabilities = {
  stage = true,
  unstage = true,
  commit = true,
  diff = true,
}

--- Global options shared by every invocation: no pager, no background index
--- refresh games (gitsigns learned this the hard way), no locale-dependent
--- quoting, and literal pathspecs so a file whose name contains glob
--- metacharacters can never be expanded into something else.
local GIT = {
  'git',
  '--no-pager',
  '--no-optional-locks',
  '--literal-pathspecs',
  '-c',
  'core.quotepath=off',
  '-c',
  'gc.auto=0',
}

---@param sub string[]
---@param files string[]
---@return string[]
local function build(sub, files)
  local cmd = vim.deepcopy(GIT)
  vim.list_extend(cmd, sub)
  if files then
    vim.list_extend(cmd, files)
  end
  return cmd
end

-- ▏ root detection ───────────────────────────────────────────────────────────

--- `.git` may be a directory (normal clone) or a file holding `gitdir: <path>`
--- (linked worktree, submodule).  Both mean "this directory is a repo root",
--- but a leftover/stale marker must not be trusted, since the async probe is the
--- only thing that can tell a real repository from debris.
--- Resolve the directory that holds the git metadata for `dir` (the directory
--- containing `HEAD`, `index`, `objects`).
---
--- For an ordinary clone that is `<dir>/.git`; for a linked worktree or a
--- submodule `.git` is a *file* holding `gitdir: <path>` and the target lives
--- outside the worktree.  Returns the normalised directory, or nil when `dir`
--- does not look like a repository root.
---@param dir string
---@return string?
local function gitdir_at(dir)
  local marker = vim.fs.joinpath(dir, '.git')
  local stat = vim.uv.fs_stat(marker)
  if not stat then
    return nil
  end
  if stat.type == 'directory' then
    -- A real repository always has HEAD here; an empty stray .git does not.
    local head = vim.uv.fs_stat(vim.fs.joinpath(marker, 'HEAD'))
    return head and base.normalize(marker) or nil
  end
  if stat.type ~= 'file' then
    return nil
  end
  local fd = vim.uv.fs_open(marker, 'r', 438)
  if not fd then
    return nil
  end
  local data = vim.uv.fs_read(fd, 512, 0)
  vim.uv.fs_close(fd)
  local gitdir = type(data) == 'string' and data:match('^gitdir:%s*(.+)')
  gitdir = gitdir and gitdir:gsub('%s+$', '') or nil
  if not gitdir or gitdir == '' then
    return nil
  end
  if gitdir:sub(1, 1) ~= '/' and not gitdir:match('^%a:[/\\]') then
    -- Linked worktrees and submodules may store a path relative to `dir`.
    gitdir = vim.fs.joinpath(dir, gitdir)
  end
  local target = vim.uv.fs_stat(gitdir)
  return (target and target.type == 'directory') and base.normalize(gitdir) or nil
end

---@param dir string
---@return string?
local function marker_at(dir)
  return gitdir_at(dir) and dir or nil
end

--- The directory the repository runtime watches for index changes.  For a
--- worktree/submodule this is *not* under the root, which is why git publishes
--- it separately from `keyfile`.
---@param root string
---@return string?
function M.metadata_dir(root)
  return gitdir_at(base.normalize(root))
end

--- Synchronous fallback.  Cheap, but not authoritative — `get_root_async` is.
---@param path string
---@return string?
function M.find_root_sync(path)
  return base.find_root_upwards(path, marker_at)
end

---@param path string
---@param cb fun(err: string?, root: string?)
function M.get_root_async(path, cb)
  exec.run(build({ 'rev-parse', '--show-toplevel' }), { cwd = base.dirname_of(path) }, function(err, res)
    if err then
      return cb(err)
    end
    local root = exec.split_lines(res.stdout)[1]
    if not root or root == '' then
      return cb('git: empty --show-toplevel output')
    end
    cb(nil, base.normalize(root))
  end)
end

-- ▏ status ───────────────────────────────────────────────────────────────────

--- Porcelain status characters that exist in either column.
local STATUS_MAP = {
  M = 'modified',
  A = 'added',
  D = 'deleted',
  R = 'renamed',
  -- Copies are only reported when copy detection is enabled; the enum has no
  -- separate `copied` state, and for display purposes a copy is a rename.
  C = 'renamed',
  T = 'typechange',
  U = 'conflicted',
  ['?'] = 'untracked',
  ['!'] = 'ignored',
}

--- X is the index column, Y the worktree column.
---@param x string
---@param y string
---@return vcssign.FileStatus?
local function parse_xy(x, y)
  if x == '?' and y == '?' then
    return { worktree = 'untracked' }
  end
  if x == '!' and y == '!' then
    -- `!!` only appears with `--ignored`, which the status command does not
    -- pass today; kept so ignored files can be enabled later without a
    -- parser change.
    return { worktree = 'ignored' }
  end
  -- Unmerged combinations: UU AU UD UA DU, plus the two "both sides" cases.
  if x == 'U' or y == 'U' or (x == 'A' and y == 'A') or (x == 'D' and y == 'D') then
    return { index = 'conflicted', worktree = 'conflicted' }
  end
  local index, worktree = STATUS_MAP[x], STATUS_MAP[y]
  if not index and not worktree then
    return nil
  end
  return { index = index, worktree = worktree }
end

--- Parse `--porcelain=v1 -z` output.
---
--- Records are NUL separated.  A rename/copy record is *two* records in a row:
--- the new path, then the original path (the "->" form only appears in the
--- non-`-z` output, which we never use).
---@param stdout string
---@param root string
---@return vcssign.StatusEntry[]
function M.parse_status(stdout, root)
  local records = exec.split_nul(stdout)
  local entries = {}
  local i = 1
  while i <= #records do
    local record = records[i]
    local x, y = record:sub(1, 1), record:sub(2, 2)
    local rel = record:sub(4)
    local status = parse_xy(x, y)
    if status and rel ~= '' then
      -- Only the index column can carry R/C in porcelain v1; the worktree
      -- column never does, and consuming an extra record on a stray match
      -- would swallow the next real entry.
      if x == 'R' or x == 'C' then
        status.orig_path = records[i + 1]
        i = i + 1
      end
      entries[#entries + 1] = base.make_entry(root, rel, status)
    end
    i = i + 1
  end
  return entries
end

---@param root string
---@param cb fun(err: string?, entries: vcssign.StatusEntry[]?)
function M.status(root, cb)
  local cmd = build({ 'status', '--porcelain=v1', '-z', '--untracked-files=all' })
  exec.run(cmd, { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    local ok, entries = pcall(M.parse_status, res.stdout, root)
    if not ok then
      return cb('git: failed to parse status output: ' .. tostring(entries))
    end
    cb(nil, entries)
  end)
end

-- ▏ actions ──────────────────────────────────────────────────────────────────

---@param root string
---@param files string[]  paths relative to `root`
---@param cb fun(err: string?)
function M.stage(root, files, cb)
  if #files == 0 then
    return cb(nil)
  end
  local cmd = build({ 'add', '--' }, files)
  exec.run(cmd, { cwd = root }, function(err)
    cb(err)
  end)
end

--- `git restore --staged` needs git >= 2.23.  Rather than parsing versions we
--- try it once and remember the failure, falling back to `git reset HEAD --`.
--- Both failure modes matter: an older git has no such *subcommand*
--- ("is not a git command"), while a future option change would report
--- "unknown option".
---@type boolean
local unstage_needs_reset = false

---@param root string
---@param files string[]
---@param cb fun(err: string?)
function M.unstage(root, files, cb)
  if #files == 0 then
    return cb(nil)
  end
  local sub = unstage_needs_reset and { 'reset', 'HEAD', '--' } or { 'restore', '--staged', '--' }
  exec.run(build(sub, files), { cwd = root }, function(err)
    if err and not unstage_needs_reset then
      local lower = err:lower()
      if lower:match('not a git command') or lower:match('unknown option') then
        unstage_needs_reset = true
        return M.unstage(root, files, cb)
      end
    end
    cb(err)
  end)
end

---@param root string
---@param files string[]  paths relative to `root`
---@param msg string
---@param cb fun(err: string?, info: string?)
function M.commit(root, files, msg, cb)
  if #files == 0 then
    -- `git commit -m msg --` with no path commits the whole index, which is
    -- never what a "commit these files" caller means.
    return cb('git: refusing to commit an empty file list')
  end
  local cmd = build({ 'commit', '-m', msg, '--' }, files)
  exec.run(cmd, { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res and exec.first_line(res.stdout) or nil)
  end)
end

--- Unified diff of one file vs HEAD (`opts.cached` diffs the index instead).
---@param root string
---@param file string  path relative to `root`
---@param opts { cached?: boolean }
---@param cb fun(err: string?, text: string?)
function M.diff(root, file, opts, cb)
  local sub = { 'diff', '--no-color' }
  if opts and opts.cached then
    sub[#sub + 1] = '--cached'
  else
    sub[#sub + 1] = 'HEAD'
  end
  exec.run(build(sub, { '--', file }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

return M
