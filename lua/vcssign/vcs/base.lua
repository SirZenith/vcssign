--- The `VcsSystem` interface: type definitions plus the helpers every adapter
--- shares (path normalisation, upward root search, unsupported-capability stubs).
---
--- The interface is intentionally documented as emmylua classes only — there is
--- no runtime base object to inherit from, adapters are plain tables.  See
--- impl/init/01-vcs-adapter.md §3.
local M = {}

local is_windows = vim.uv.os_uname().sysname == 'Windows_NT'

--- `vim.fs.normalize` expands `$VAR` by default, which would corrupt a path that
--- legitimately contains a string like `$HOME` (paths coming out of git/svn are
--- always literal).  `~` expansion is unaffected and stays enabled.
local NORMALIZE_OPTS = { expand_env = false }

--- What a system can actually do; actions check this before calling into it.
---@class vcssign.VcsCaps
---@field stage boolean         can move changes into the index (git only)
---@field staged_signs boolean  has the HEAD/index/worktree trio, so `staged` signs are meaningful (git only)
---@field revert_hunk boolean   can drop a single hunk (a reverse `apply_patch`)
---@field blame boolean         can attribute lines to the revision that last touched them
---@field show_rev boolean      can read a file as of a revision (`show`)
---@field commit boolean

--- A `-L from,to` window for `blame`.  svn has no line window and ignores it;
--- the whole file comes back either way, so `lines` is a sparse map keyed by
--- final line number instead of a dense array.
---@class vcssign.BlameOpts
---@field from integer?  1-based first line, inclusive
---@field to integer?    1-based last line, inclusive
---@field ignore_whitespace boolean?  ignore whitespace-only changes (git's `-w`)
---@field extra_opts string[]?  extra arguments appended to the blame command (git)

--- Where one final line came from.  `rev` is whatever `show` accepts for that
--- line: a 40-hex object id for git, a revision number as text for svn.
---@class vcssign.BlameLine
---@field rev string       git: the 40-hex object id; svn: the revision number as text ('-' = locally modified)
---@field author string
---@field time integer?    Unix seconds, when the VCS reports one (git: the *author* time)
---@field summary string?  git: the commit summary line
--- The fields below mirror what gitsigns hands to `current_line_blame_formatter`
--- (expanded by `vcssign.blame_formatter`).  All of them are optional: no single
--- adapter fills every one in (svn has no `summary`, git has no `kind`, ...).
---@field filename string?     the path the VCS reports for the blamed file
---@field orig_lnum integer?   the line's number in the commit that introduced it
---@field final_lnum integer?  the line's number in the blamed file
---@field author_name string?  `author`, under gitsigns' name for it
---@field author_mail string?  the bare address (no angle brackets)
---@field author_time integer? Unix seconds of the author date
---@field author_tz string?    `+HHMM`
---@field committer string?
---@field committer_mail string?
---@field committer_time integer?
---@field committer_tz string?
---@field previous string?     `<sha> <filename>`: the commit blamed before a rename

--- Result of `blame`: `lines[n]` attributes final line `n`, holes are lines
--- outside a `-L` window (or lines the VCS skipped).  `max_lineno` is the
--- highest final line number seen, `0` when nothing was reported.
---@class vcssign.BlameResult
---@field lines table<integer, vcssign.BlameLine>
---@field max_lineno integer

---@alias vcssign.BlameCb fun(err: string?, result: vcssign.BlameResult?)

--- How `apply_patch` should apply its patch.
---@class vcssign.PatchOpts
---@field cached boolean?   apply to the index instead of the worktree (git only)
---@field reverse boolean?  apply the patch backwards, i.e. drop the hunk

--- Every callback in this interface is error-first: `cb(err, ...)`.
---@class vcssign.VcsSystem
---@field name string
---@field keyfile string  marker used by the synchronous fallback scan (`.git` / `.svn`); also the
---                        path the M2 fs watcher subscribes to
---@field capabilities vcssign.VcsCaps
--- Sync best-effort root lookup; may return nil even inside a repo (the async
--- value is authoritative).
---@field find_root_sync fun(path: string): string?
--- Directory holding the VCS metadata (`.git` / `.svn`).  Optional: repository
--- runtimes fall back to `<root>/<keyfile>`.
---
--- It differs from the keyfile for git worktrees and submodules, where `.git` is
--- a *file* whose `gitdir:` target (outside the worktree) holds the real index —
--- the only place a staging change can be observed.
---@field metadata_dir? fun(root: string): string?
--- Authoritative root lookup through the VCS itself.
---@field get_root_async fun(path: string, cb: fun(err: string?, root: string?))
--- Baseline text of `rel` as of `rev`; `rev == 'index'` means the staging
--- baseline (git's index, svn's BASE — D42).
---@field show fun(root: string, rev: string, rel: string, cb: fun(err: string?, text: string?))
--- Whether `rel` is under version control.  Untracked is `false`, not an error.
---@field is_tracked fun(root: string, rel: string, cb: fun(err: string?, tracked: boolean?))
--- Per-line attribution.  svn ignores `opts` (no line window).
---@field blame fun(root: string, rel: string, opts: vcssign.BlameOpts, cb: vcssign.BlameCb)
--- Apply a unified diff to the worktree or the index.  A patch that does not
--- apply cleanly is an error, and svn is detected through its stdout because it
--- still exits `0` on a conflict.
---@field apply_patch fun(root: string, patch: string, opts: vcssign.PatchOpts, cb: fun(err: string?))
--- Throw away the worktree change to `rel` (back to the index/BASE text).
---@field revert fun(root: string, rel: string, cb: fun(err: string?))
---@field stage fun(root: string, files: string[], cb: fun(err: string?))
---@field unstage fun(root: string, files: string[], cb: fun(err: string?))
---@field commit fun(root: string, files: string[], msg: string, cb: fun(err: string?, info: string?))
---@field diff fun(root: string, file: string, opts: { cached?: boolean }, cb: fun(err: string?, text: string?))

--- Absolute, normalised, no trailing separator.
---@param path string
---@return string
function M.normalize(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'), NORMALIZE_OPTS)
end

--- Directory to run VCS commands in for `path`: the path itself when it is an
--- existing directory, its parent otherwise (buffer names are files).
---@param path string
---@return string
function M.dirname_of(path)
  local stat = vim.uv.fs_stat(path)
  if stat and stat.type == 'directory' then
    return M.normalize(path)
  end
  return M.normalize(vim.fs.dirname(path))
end

--- Map key for an absolute path that has already been through `M.normalize`.
---
--- Identical to the path on POSIX; case-folded on Windows, where `D:/Repo` and
--- `d:/repo` are the same directory and two different keys would otherwise mean
--- two caches (and two watchers) for one repository.
---@param path string
---@return string
function M.path_key(path)
  return is_windows and path:lower() or path
end

--- Absolute path of `rel` inside `root`.
---
--- `root` must already be absolute (adapters always hand out roots that went
--- through `M.normalize`), so this stays a pure-Lua call: it runs per file on
--- every sign refresh, and `fnamemodify(':p')` there is measurable in large
--- repositories.
---@param root string
---@param rel string
---@return string
function M.abspath(root, rel)
  if rel == '' then
    return vim.fs.normalize(root, NORMALIZE_OPTS)
  end
  return vim.fs.normalize(vim.fs.joinpath(root, rel), NORMALIZE_OPTS)
end

--- Inverse of `M.abspath`: `path` relative to `root`, or nil when it is outside.
--- Case-insensitive on Windows, where drive/path casing is not significant.
--- Handles a root that is itself a filesystem root (`D:/`, `/`), which keeps its
--- trailing separator.
---@param path string
---@param root string
---@return string?
function M.relpath(path, root)
  local abs, base = M.normalize(path), M.normalize(root)
  local prefix = base:sub(-1) == '/' and base or base .. '/'
  if is_windows then
    if abs:lower() == base:lower() then
      -- The root itself: `''`, not nil.  The prefix above is one character
      -- longer than the root, so without this branch the comparison below can
      -- never match it - and `active()` in a session whose cwd *is* the
      -- repository root (fresh `cd repo && nvim`) resolved nothing.
      return ''
    end
    if abs:lower():sub(1, #prefix) ~= prefix:lower() then
      return nil
    end
  else
    if abs == base then
      return ''
    end
    if abs:sub(1, #prefix) ~= prefix then
      return nil
    end
  end
  return abs:sub(#prefix + 1)
end

--- Walk upwards from `path` and return the first root accepted by `matcher`.
---@param path string
---@param matcher fun(dir: string): string?  returns a root, or nil to keep walking
---@return string?
function M.find_root_upwards(path, matcher)
  local dir = M.dirname_of(path)
  while dir and dir ~= '' do
    local root = matcher(dir)
    if root then
      return M.normalize(root)
    end
    local parent = vim.fs.dirname(dir)
    if not parent or parent == dir then
      return nil
    end
    dir = parent
  end
  return nil
end

--- Stub for a capability an adapter does not implement.  The last argument of
--- every capability method is its callback, so the error always reaches the
--- caller instead of exploding as a nil call.
---@param name string
---@return fun(...): nil
function M.unsupported(name)
  return function(...)
    local argc = select('#', ...)
    local cb = argc > 0 and select(argc, ...) or nil
    if type(cb) == 'function' then
      cb(string.format('capability unsupported: %s', name))
    end
  end
end

return M
