--- The `VcsSystem` interface: type definitions plus the helpers every adapter
--- shares (path normalisation, upward root search, unsupported-capability stubs).
---
--- The interface is intentionally documented as emmylua classes only — there is
--- no runtime base object to inherit from, adapters are plain tables.  See
--- loop/archive/vcs/2026-10-16T17-33-54-vcs-adapter-git-svn.md §3.
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
---@field summary string?  the commit summary line (first line of the message)
--- The fields below mirror what gitsigns hands to `current_line_blame_formatter`
--- (expanded by `vcssign.blame_formatter`).  All of them are optional: no single
--- adapter fills every one in (svn has no `author_mail` or `previous`, git has no `kind`, ...).
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

--- What one `status` entry says about a path.
---
--- "Staged" means the staging baseline (git's index, svn's BASE) differs from
--- `HEAD` — i.e. the second layer of signs has something to say.  svn has no
--- staging area, so it never sets it (`capabilities.staged_signs == false`).
---@class vcssign.FileStatus
---@field tracked boolean   false for an untracked *or* ignored path
---@field staged boolean    the index/BASE differs from HEAD
---@field worktree boolean  the worktree differs from the index/BASE
---@field ignored boolean?  not under version control because it is ignored
---@field dir boolean?      the entry is an ignored directory, not a file

--- A long-lived child that answers `show`'s question without one process per
--- file (perf P0-2).
---
--- The protocol is the adapter's business; what callers may rely on is that a
--- failed read reports an error rather than answering with something, and that
--- `closed` becomes true once the child is gone — a caller holding a reader must
--- then drop it instead of retrying through it.
---@class vcssign.BlobReader
---@field closed boolean  no more reads will be answered
---@field read fun(self: vcssign.BlobReader, rev: string, rel: string, cb: fun(err: string?, text: string?))
---@field close fun(self: vcssign.BlobReader)  shut the child down; safe to call twice

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

-- Whether `metadata_dir` has to be watched *recursively* to see every baseline
-- change.  Defaults to true: git keeps its index, `HEAD` and `refs/` spread
-- across the git directory, and a worktree's `logs/` moves independently.  An
-- adapter whose baseline store is a single file directly inside `metadata_dir`
-- sets this to false -- svn's `.svn/wc.db` is one file, and on a big working
-- copy the tree under `.svn/pristine/` holds thousands of files whose events
-- nothing reads (measured: 3135 callbacks for a 300-file `svn commit` recursive,
-- 1225 non-recursive, `wc.db` alone 1; see perf §3.5 S1).
---@field metadata_recursive? boolean
--- A free (no subprocess) change-detection key for the baseline store — the
--- entries `show(rev, rel)` answers from — or nil when the adapter cannot
--- produce a trustworthy one.
---
--- It is what lets a refresh skip re-reading a baseline that cannot have moved
--- (perf P0-4): `attach` compares it against the value recorded when the current
--- `base_text` was read, and re-reads on any difference.  Returning nil is
--- always safe — the caller then re-reads every time, which is the behaviour
--- without a fingerprint — while a key that misses one of the inputs makes the
--- signs stale, so when in doubt return nil.
---@field baseline_stamp? fun(root: string): string?
--- Authoritative root lookup through the VCS itself.
---@field get_root_async fun(path: string, cb: fun(err: string?, root: string?))
--- One whole-repository status query: which paths differ from what, and how.
---
--- Optional, and the point is arithmetic: without it every attached buffer
--- costs its own `is_tracked` + `show` (3 processes for git), while one answer
--- covers the whole repository — and a path the answer stays silent about is
--- by definition in sync with its baseline, so it needs no baseline read at
--- all (perf P0-1).
---
--- Keys of `entries` are absolute, normalised paths.  A path that is *absent*
--- is "tracked and unmodified"; everything else says otherwise.  An entry whose
--- `dir` flag is set is an ignored **directory**: paths below it are untracked
--- even though the query names only the directory (git collapses ignored trees
--- to one record, `traditional` mode — walking them individually would cost
--- more than the reads it saves).
---@field status? fun(root: string, cb: fun(err: string?, entries: table<string, vcssign.FileStatus>?))
--- Baseline text of `rel` as of `rev`; `rev == 'index'` means the staging
--- baseline (git's index, svn's BASE — D42).
---@field show fun(root: string, rev: string, rel: string, cb: fun(err: string?, text: string?))
--- Open a reader for `show`'s answers — the same text through one process
--- instead of one process per file.
---
--- Optional, and only worth it where the VCS has a batch protocol (git's
--- `cat-file --batch`); svn has none, so its adapter leaves this out and every
--- read stays a `svn cat`.  Never returns nil: a reader that could not start
--- comes back closed, which is the same thing to the caller as an adapter
--- without the hook.
---@field open_blob_reader? fun(root: string): vcssign.BlobReader
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

--- A cheap change-detection key for one filesystem entry, for the baseline
--- fingerprints in `attach.lua` (perf P0-4): a missing entry is `-`, and every
--- other answer carries inode, size and nanosecond mtime, so a rewrite that
--- keeps the size still produces a different key.
---
--- `vim.uv.fs_stat` is a syscall, not a subprocess: this is the whole reason a
--- refresh can answer "did the baseline store move" for free.
---@param path string
---@return string
function M.stat_key(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return '-'
  end
  local mtime = stat.mtime or {}
  return string.format(
    '%s:%s:%s:%s.%s',
    tostring(stat.ino or 0),
    tostring(stat.size or 0),
    tostring(mtime.sec or 0),
    tostring(mtime.nsec or 0),
    tostring(stat.type or '?')
  )
end

--- The adapter's baseline fingerprint, or `nil` when it cannot answer.
---
--- The optional `baseline_stamp` hook is pcall'd **here** and nowhere else: an
--- adapter that raises must degrade to "no fingerprint", and every caller (the
--- render short-circuit, the blame cache) wants the same answer to the question
--- "did the store move".  `nil` always means "cannot tell", never "unchanged".
---@param system vcssign.VcsSystem
---@param root string
---@return string?
function M.stamp(system, root)
  local fn = system and system.baseline_stamp
  if not fn then
    return nil
  end
  local ok, stamp = pcall(fn, root)
  if ok and type(stamp) == 'string' then
    return stamp
  end
  return nil
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
