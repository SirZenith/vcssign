--- svn adapter.
---
--- See impl/init/01-vcs-adapter.md §5.  Everything here was verified against a
--- real working copy (svn 1.14.5 on Windows).  The three things that shape the
--- code:
---   * paths are printed verbatim (spaces, UTF-8 bytes, no quoting), so the
---     adapter always hands svn an absolute path argument and never re-parses
---     one out of svn's output;
---   * `blame --xml` splits attributes and elements across lines, so the parser
---     is structure-tolerant rather than line-oriented (measured: 43.9ms for
---     200 lines vs 141.1ms for the plain-text form);
---   * `svn patch` cannot read a patch from stdin — 1.14.5 answers with
---     `svn.EXE: invalid option:` — so a temporary file carries it, and because
---     a *rejected* hunk still exits 0 (§5.3) the outcome has to be read out of
---     stdout instead of the exit code.
---
--- svn has no index: the staging baseline (`rev == 'index'`) is BASE (D42).
local exec = require('vcssign.exec')
local base = require('vcssign.vcs.base')

local M = {}

M.name = 'svn'
M.keyfile = '.svn'
M.capabilities = {
  stage = false, -- svn has no staging area
  staged_signs = false,
  revert_hunk = true, -- a reverse `svn patch` drops a hunk (measured)
  blame = true,
  show_rev = true,
  commit = true,
}

local SVN = { 'svn', '--non-interactive' }

---@param args string[]
---@return string[]
local function build(args)
  local cmd = vim.deepcopy(SVN)
  vim.list_extend(cmd, args)
  return cmd
end

-- ▏ root detection ───────────────────────────────────────────────────────────

---@param dir string
---@return string?
local function marker_at(dir)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(dir, '.svn'))
  return stat and stat.type == 'directory' and dir or nil
end

---@param path string
---@return string?
function M.find_root_sync(path)
  return base.find_root_upwards(path, marker_at)
end

---@type boolean
local warned_no_show_item = false

--- `svn info --show-item wc-root` needs svn >= 1.9.  When the option is
--- unsupported we degrade to the (already computed) marker-scan result rather
--- than failing, and say so once.
---@param path string
---@param cb fun(err: string?, root: string?)
function M.get_root_async(path, cb)
  exec.run(
    build({ 'info', '--show-item', 'wc-root' }),
    { cwd = base.dirname_of(path) },
    function(err, res)
      if not err then
        local root = exec.split_lines(res.stdout)[1]
        if root and root ~= '' then
          return cb(nil, base.normalize(root))
        end
        err = 'svn: empty wc-root output'
      end
      if err:lower():match('invalid option') or err:lower():match('unknown option') then
        if not warned_no_show_item then
          warned_no_show_item = true
          vim.notify(
            'vcssign: this svn does not support --show-item (< 1.9); using the marker scan for root detection',
            vim.log.levels.WARN
          )
        end
        return cb(nil, M.find_root_sync(path))
      end
      cb(err)
    end
  )
end

-- ▏ the sign primitives ─────────────────────────────────────────────────────

--- Absolute argument for every file-scoped svn command.  svn prints paths
--- verbatim and Windows working copies use backslashes, so keeping the path
--- absolute and handing it straight to argv avoids a re-parse that could not
--- round-trip a name containing spaces.
---@param root string
---@param rel string
---@return string
local function abspath(root, rel)
  return base.abspath(root, rel)
end

--- Baseline text of `rel` as of `rev`, with `'index'` mapped to `BASE` — the
--- git-index equivalent (D42).
---
--- Measured (§5.3): an unversioned target exits non-zero with
--- `svn: warning: W200005: '<abs>' is not under version control` followed by
--- `svn: E200009: Could not cat all targets because some targets don't exist`;
--- `-r 99` on a repository with fewer revisions answers
--- `svn: E160006: No such revision 99`; `-r PREV` on revision 0 answers
--- `svn: E195012: Unable to find repository location ... in revision 0`.
---@param root string
---@param rev string  a revision, or 'index' for BASE
---@param rel string
---@param cb fun(err: string?, text: string?)
function M.show(root, rev, rel, cb)
  local r = rev == 'index' and 'BASE' or rev
  exec.run(build({ 'cat', '-r', r, abspath(root, rel) }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

--- Whether `rel` is under version control, decided by `svn info`'s exit code.
---
--- `svn status` cannot answer this: a path that does not exist produces *no*
--- output at all (exit 0), which reads as "tracked" — the wart this replaced.
--- `svn info` fails for every path it cannot describe, and the texts below are
--- all "not tracked", i.e. an answer rather than a failure:
---   * measured: `W155010: The node '<abs>' was not found.` (an unversioned
---     *or* nonexistent path) followed by `E200009: Could not display info for
---     all targets because some targets don't exist`;
---   * measured (svn 1.14.5): `E155007: '<abs>' is not a working copy` outside
---     any working copy; older builds spell it `W155007`;
---   * `not under version control` (W200005), kept defensively.
--- A *missing but tracked* path (status `!`) still answers `info` with exit 0,
--- which is the wanted answer: it is under version control.
--- Only an unrecognised non-zero exit is reported as an error.
---@param root string
---@param rel string
---@param cb fun(err: string?, tracked: boolean?)
function M.is_tracked(root, rel, cb)
  exec.run(build({ 'info', '--', abspath(root, rel) }), { cwd = root }, function(err, res)
    if not err then
      return cb(nil, true)
    end
    -- `err` is `exec.error_message`, which keeps only the *first* stderr line,
    -- so match the full stderr channel as well.
    local text = ((res and res.stderr) or '') .. ' ' .. err
    local lower = text:lower()
    if
      lower:match('not under version control')
      or lower:match('not a working copy')
      or text:match('E200009')
      or text:match('W155010')
      or text:match('E155007')
      or text:match('W155007')
    then
      return cb(nil, false)
    end
    cb(err)
  end)
end

--- Parse `svn blame --xml` into `{[lineno] = vcssign.BlameLine}`.
---
--- svn spreads one `<entry>` over several lines and omits the whole `<commit>`
--- element for a line that only exists in the working copy, which is how a
--- locally modified line is recognised (`rev = '-'`, `author = '-'`).
---@param stdout string
---@return vcssign.BlameResult
function M.parse_blame(stdout)
  local lines = {}
  local max_lineno = 0
  for attrs, body in stdout:gmatch('<entry%s*([^>]*)>(.-)</entry>') do
    local lineno = tonumber(attrs:match('line%-number="(%d+)"'))
    if lineno then
      local revision = body:match('<commit%s+revision="(%d+)"')
      lines[lineno] = {
        rev = revision or '-',
        author = (revision and body:match('<author>(.-)</author>')) or '-',
      }
      if lineno > max_lineno then
        max_lineno = lineno
      end
    end
  end
  return { lines = lines, max_lineno = max_lineno }
end

--- Per-line attribution, whole file.
---
--- svn has no `-L` line window (`opts` is accepted for interface symmetry and
--- ignored); the cache that keeps this from costing a process per sign lives in
--- `blame.lua`.  Blaming the working copy — rather than `-r BASE` — is
--- deliberate: the uncommitted lines are exactly the ones a user needs marked.
---@param root string
---@param rel string
---@param _opts vcssign.BlameOpts
---@param cb fun(err: string?, result: vcssign.BlameResult?)
function M.blame(root, rel, _opts, cb)
  exec.run(build({ 'blame', '--xml', abspath(root, rel) }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    local ok, result = pcall(M.parse_blame, res.stdout)
    if not ok then
      return cb('svn: failed to parse blame output: ' .. tostring(result))
    end
    cb(nil, result)
  end)
end

-- ▏ actions ──────────────────────────────────────────────────────────────────

M.stage = base.unsupported('stage')
M.unstage = base.unsupported('unstage')

--- Apply a unified diff to the working copy.
---
--- The patch goes through a temporary file because svn 1.14.5 refuses stdin.
--- `--strip N` drops N leading path components, which is measured to matter:
--- a bare unidiff (`--- f`) and svn's own format (with `Index:`) apply at
--- `--strip 0`, while a git-style patch (`--- a/f` / `+++ b/f`) is *rejected*
--- there and only applies at `--strip 1` (`--strip 2` fails outright with
--- `svn: E195018: Cannot strip 2 components from 'f.txt'`).  We keep
--- `--strip 0` (the svn-native dialect) and require callers to emit bare
--- headers; `hunk.compose` must not add the `a/`+`b/` prefixes.
---
--- A conflict is NOT an error to svn (§5.3): it exits 0 and writes
--- `<file>.svnpatch.rej` while printing `C         <path>` and
--- `>         rejected hunk ...`.  The rejection is therefore read from stdout
--- and turned into an error here.  The `.rej` file is left behind so the user
--- can inspect the conflict; only our own temporary patch file is removed.
---@param root string
---@param patch string
---@param opts vcssign.PatchOpts
---@param cb fun(err: string?)
function M.apply_patch(root, patch, opts, cb)
  opts = opts or {}
  local tmp = vim.fn.tempname()
  local fd = vim.uv.fs_open(tmp, 'w', 384)
  if not fd then
    return cb('svn: cannot create a temporary patch file')
  end
  vim.uv.fs_write(fd, patch, 0)
  vim.uv.fs_close(fd)

  local args = { 'patch', '--strip', '0' }
  if opts.reverse then
    args[#args + 1] = '--reverse-diff'
  end
  args[#args + 1] = tmp

  exec.run(build(args), { cwd = root }, function(err, res)
    pcall(vim.uv.fs_unlink, tmp)
    if err then
      return cb(err)
    end
    local rejected
    for _, line in ipairs(exec.split_lines(res.stdout)) do
      if line:match('^C%s') or line:find('rejected hunk', 1, true) then
        rejected = rejected or line
      end
    end
    if rejected then
      return cb('svn: patch did not apply cleanly: ' .. rejected:gsub('%s+', ' '):gsub('^%s+', ''))
    end
    cb(nil)
  end)
end

--- Throw the working copy back to BASE: `svn revert <abs>` (measured to drop
--- the modification outright, including a deleted file).
---@param root string
---@param rel string
---@param cb fun(err: string?)
function M.revert(root, rel, cb)
  exec.run(build({ 'revert', abspath(root, rel) }), { cwd = root }, function(err)
    cb(err)
  end)
end

---@param root string
---@param files string[]
---@param msg string
---@param cb fun(err: string?, info: string?)
function M.commit(root, files, msg, cb)
  if #files == 0 then
    return cb('svn: refusing to commit an empty file list')
  end
  exec.run(build({ 'commit', '-m', msg, '--' }, files), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    -- stdout is a progress list (`Sending   base.txt` ...); the useful summary
    -- line is the revision.  Fall back to the first line for other svn builds.
    local stdout = (res and res.stdout) or ''
    cb(nil, stdout:match('Committed revision %d+') or exec.first_line(stdout))
  end)
end

---@param root string
---@param file string  path relative to `root`
---@param _opts table   unused: svn has no index to diff against
---@param cb fun(err: string?, text: string?)
function M.diff(root, file, _opts, cb)
  exec.run(build({ 'diff', '--', file }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

return M
