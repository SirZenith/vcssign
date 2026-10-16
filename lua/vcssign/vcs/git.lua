--- git adapter.
---
--- See loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md §4.  Three things differ from the
--- vcs-helper.nvim reference implementation on purpose:
---   1. root detection asks git itself (worktrees and submodules, where `.git`
---      is a *file*, cannot be found by a pure marker scan);
---   2. the staging baseline is read as a blob (`show :<rel>`), so paths
---      containing spaces, quotes or non-ASCII bytes need no quoting/escaping
---      handling at all;
---   3. every path the adapter reports is anchored at the repo root, never at
---      the editor's cwd.
---
--- Baseline (§5.2, measured against git 2.55):
---   * untracked file -> exit 128
---     `fatal: path 'u.txt' exists on disk, but not in the index`
---   * conflicted file -> exit 128
---     `fatal: path 'c.txt' is in the index, but not at stage 0`, plus a hint
---     suggesting `:1:c.txt`
---   * unborn HEAD -> exit 128 `fatal: invalid object name 'HEAD'.` for
---     `HEAD:<rel>`, while `:<rel>` still answers — so the `index` baseline is
---     the only one a fresh repository can serve.
local exec = require('vcssign.exec')
local base = require('vcssign.vcs.base')

local M = {}

M.name = 'git'
M.keyfile = '.git'
M.capabilities = {
  stage = true,
  staged_signs = true,
  revert_hunk = true,
  blame = true,
  show_rev = true,
  commit = true,
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
  exec.run(
    build({ 'rev-parse', '--show-toplevel' }),
    { cwd = base.dirname_of(path) },
    function(err, res)
      if err then
        return cb(err)
      end
      local root = exec.split_lines(res.stdout)[1]
      if not root or root == '' then
        return cb('git: empty --show-toplevel output')
      end
      cb(nil, base.normalize(root))
    end
  )
end

-- ▏ the sign primitives ─────────────────────────────────────────────────────

--- Baseline text of `rel` as of `rev`; `rev == 'index'` reads the staged blob
--- (`:<rel>`), which is what the sign column diffs against (D42).  A missing
--- blob is an error, not an empty string — the caller decides whether an
--- untracked file means "empty baseline" and asks `is_tracked` first.
---@param root string
---@param rev string  a revision name, or 'index' for the staging baseline
---@param rel string  path relative to `root`
---@param cb fun(err: string?, text: string?)
function M.show(root, rev, rel, cb)
  local spec = rev == 'index' and (':' .. rel) or (rev .. ':' .. rel)
  exec.run(build({ 'show', spec }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

--- Whether `rel` is under version control.
---
--- `git ls-files --error-unmatch` exits 1 with `error: pathspec '<rel>' did not
--- match any file(s) known to git` for an untracked path.  That exit code *is*
--- the answer (§5.2), not a failure, so it must not be reported as one; only a
--- higher code (or a signal) is a real error.
---@param root string
---@param rel string
---@param cb fun(err: string?, tracked: boolean?)
function M.is_tracked(root, rel, cb)
  exec.run(
    build({ 'ls-files', '--error-unmatch', '--' }, { rel }),
    { cwd = root },
    function(err, res)
      if err then
        if res and res.code == 1 then
          return cb(nil, false)
        end
        return cb(err)
      end
      cb(nil, true)
    end
  )
end

--- Parse `git blame --line-porcelain` output into `{[lineno] = vcssign.BlameLine}`.
---
--- The header is `<40hex sha> <orig_lineno> <final> <num_lines>`, where the
--- **third** field is the final line number and the fourth is only present on
--- the *first* line of a group (git omits it once it has announced the group
--- size).  Metadata lines (`author`, `author-mail`, `author-time`, `author-tz`,
--- `committer*`, `summary`, `filename`, `previous`) are repeated for every line,
--- and the source text follows on a line starting with a TAB, which terminates
--- the record.  Every metadata key is kept under its porcelain name (dashes and
--- all) -- those names are what `vcssign.blame_formatter` reads.
---@param stdout string
---@return vcssign.BlameResult
function M.parse_blame(stdout)
  local lines = {}
  local max_lineno = 0
  local pending ---@type { sha: string, orig: integer, final: integer }?
  local meta = {}
  --- `author-mail` arrives as `<ada@example.com>`; the formatter wants the bare
  --- address.
  local function mail(value)
    if not value then
      return nil
    end
    return value:match('<(.*)>') or value
  end
  for _, line in ipairs(exec.split_lines(stdout)) do
    if line:sub(1, 1) == '\t' then
      if pending then
        local n = pending.final
        lines[n] = {
          rev = pending.sha,
          orig_lnum = pending.orig,
          final_lnum = n,
          author = meta.author or '',
          author_name = meta.author,
          author_mail = mail(meta['author-mail']),
          author_time = tonumber(meta['author-time']),
          author_tz = meta['author-tz'],
          committer = meta.committer,
          committer_mail = mail(meta['committer-mail']),
          committer_time = tonumber(meta['committer-time']),
          committer_tz = meta['committer-tz'],
          summary = meta.summary,
          filename = meta.filename,
          previous = meta.previous,
          -- kept for the float and for callers that only want the date
          time = tonumber(meta['author-time']),
        }
        if n > max_lineno then
          max_lineno = n
        end
      end
      pending, meta = nil, {}
    else
      -- The first line of a group carries a 4th field (the group size); the rest
      -- of the group carries only three.  Both put the FINAL line number in the
      -- 3rd field and the original one in the 2nd.
      local sha, orig, final = line:match('^(%x+) (%d+) (%d+)$')
      if not sha then
        sha, orig, final = line:match('^(%x+) (%d+) (%d+) %d+$')
      end
      if sha and #sha == 40 then
        pending = { sha = sha, orig = tonumber(orig), final = tonumber(final) }
        meta = {}
      elseif pending then
        local key, value = line:match('^(%S+) (.*)$')
        if key then
          meta[key] = value
        end
      end
    end
  end
  return { lines = lines, max_lineno = max_lineno }
end

--- Per-line attribution.  `opts` is a `-L from,to` window; omitting it blames
--- the whole file.
---
--- A worktree line that is not committed yet comes back with an all-zero sha
--- and `author Not Committed Yet` — that is information, not an error (§5.2).
---@param root string
---@param rel string
---@param opts vcssign.BlameOpts
---@param cb fun(err: string?, result: vcssign.BlameResult?)
function M.blame(root, rel, opts, cb)
  local sub = { 'blame', '--line-porcelain' }
  if opts and opts.ignore_whitespace then
    sub[#sub + 1] = '-w'
  end
  if opts and (opts.from or opts.to) then
    local from = opts.from or 1
    sub[#sub + 1] = '-L'
    sub[#sub + 1] = string.format('%d,%d', from, opts.to or from)
  end
  if opts and opts.extra_opts then
    for _, arg in ipairs(opts.extra_opts) do
      sub[#sub + 1] = arg
    end
  end
  exec.run(build(sub, { '--', rel }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    local ok, result = pcall(M.parse_blame, res.stdout)
    if not ok then
      return cb('git: failed to parse blame output: ' .. tostring(result))
    end
    cb(nil, result)
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
    if err and not (opts and opts.cached) then
      -- A repository with no commits yet has no `HEAD` to compare against
      -- ("ambiguous argument 'HEAD'").  The staged view is the useful answer
      -- there (it is what a first commit would record), and it is what the user
      -- pressing `d` on such a row is looking for.
      local lower = err:lower()
      if lower:find('ambiguous argument', 1, true) or lower:find('unknown revision', 1, true) then
        return M.diff(root, file, { cached = true }, cb)
      end
    end
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

--- Throw away the worktree change to `rel`: `git checkout -- <rel>` restores
--- the file from the index, which is exactly the baseline the signs diff
--- against.
---@param root string
---@param rel string
---@param cb fun(err: string?)
function M.revert(root, rel, cb)
  exec.run(build({ 'checkout', '--' }, { rel }), { cwd = root }, function(err)
    cb(err)
  end)
end

--- Apply a unified diff, to the worktree or (`opts.cached`) to the index.
---
--- Measured (§5.2): the patch must be piped in as a single string and must
--- carry its own final `\n` (exec writes a string verbatim, and a missing byte
--- is exactly what makes git answer `error: corrupt patch at <stdin>:5`), and a
--- zero-context patch — the shape `hunk.compose` will produce — needs
--- `--unidiff-zero` or git refuses it.
---@param root string
---@param patch string
---@param opts vcssign.PatchOpts
---@param cb fun(err: string?)
function M.apply_patch(root, patch, opts, cb)
  opts = opts or {}
  local sub = { 'apply' }
  if opts.cached then
    sub[#sub + 1] = '--cached'
  end
  if opts.reverse then
    sub[#sub + 1] = '-R'
  end
  sub[#sub + 1] = '--unidiff-zero'
  sub[#sub + 1] = '-'
  exec.run(build(sub), { cwd = root, stdin = patch }, function(err)
    cb(err)
  end)
end

return M
