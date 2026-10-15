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
---@field stage boolean    can move changes into the index (git only)
---@field unstage boolean  can take changes back out of the index (git only)
---@field commit boolean
---@field diff boolean

--- One file, as reported by a VCS adapter.
---@class vcssign.StatusEntry
---@field path string      absolute, normalised (`D:/a/b.txt`)
---@field rel_path string  relative to the repo root, '/'-separated (`a/b.txt`)
---@field status vcssign.FileStatus

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
---@field status fun(root: string, cb: fun(err: string?, entries: vcssign.StatusEntry[]?))
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
--- through `M.normalize`), so this stays a pure-Lua call: it runs once per
--- status entry, and `fnamemodify(':p')` per entry is measurable on large
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

--- Build a `StatusEntry`.
---@param root string
---@param rel_path string
---@param status vcssign.FileStatus
---@return vcssign.StatusEntry
function M.make_entry(root, rel_path, status)
  return {
    path = M.abspath(root, rel_path),
    rel_path = rel_path,
    status = status,
  }
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
