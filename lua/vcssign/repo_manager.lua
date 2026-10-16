--- Repository lifecycle: `root -> Repo` plus reference counting.
---
--- References are opaque tokens chosen by the caller (`"buf:3"`, `"cmd"`).
--- A repository lives as long as at least one reference holds it, so several
--- buffers inside the same repository share one runtime and one watcher, and
--- only the last release disposes it.
--- See impl/init/02-repo-runtime.md §4.
local log = require('vcssign.log')
local util = require('vcssign.util')
local Repo = require('vcssign.repo')
local base = require('vcssign.vcs.base')
local registry = require('vcssign.vcs')

local uv = vim.uv

local M = {}

---@type table<string, vcssign.Repo>  root -> repo
M._by_root = {}
---@type table<string, vcssign.Repo>  reference token -> repo
M._by_ref = {}
--- Per-ref generation.  Bumped by `attach` itself (the latest attach for a
--- reference wins — two racing attaches would otherwise be resolved by
--- whichever detection happened to finish last, wherever the buffer has moved
--- since) and by every release path (`detach`, `_remove`, `dispose_all`):
--- detection is asynchronous, and a callback arriving after its reference was
--- released must not resurrect the repository (that would pin the repo — and
--- its watcher — forever).
---@type table<string, integer>
M._gen = {}
--- Session epoch, bumped by `dispose_all` only.  It invalidates every
--- detection still in flight in one stroke — including references that were
--- never bound and therefore have no `_gen` entry — so nothing may attach
--- (watchers, status commands) after everything was disposed.  Attaches after
--- the bump capture the new value and work normally.
---@type integer
M._epoch = 0
---@type function[]
M._on_attached = {}
---@type function[]
M._on_detached = {}

---@param fn fun(repo: vcssign.Repo)
---@return fun() unsubscribe
function M.on_repo_attached(fn)
  return util.subscribe(M._on_attached, fn)
end

---@param fn fun(repo: vcssign.Repo)
---@return fun() unsubscribe
function M.on_repo_detached(fn)
  return util.subscribe(M._on_detached, fn)
end

---@param root string
---@return vcssign.Repo?
function M.get(root)
  return M._by_root[base.path_key(base.normalize(root))]
end

---@return vcssign.Repo[]
function M.all()
  return vim.tbl_values(M._by_root)
end

---@return integer
function M.count()
  return vim.tbl_count(M._by_root)
end

--- How many references currently hold the repository at `root`.
---@param root string
---@return integer
function M.ref_count(root)
  local repo = M.get(root)
  return repo and vim.tbl_count(repo.refs) or 0
end

--- Deepest attached repository containing `path`.
---@param path string
---@return vcssign.Repo?
function M.get_by_path(path)
  local abs = base.normalize(path)
  local best ---@type vcssign.Repo?
  for root, repo in pairs(M._by_root) do
    if base.relpath(abs, root) and (best == nil or #root > #best.root) then
      best = repo
    end
  end
  return best
end

--- Repository for the current buffer, falling back to the editor's cwd.  This
--- is what `:Vcssign` targets when it is not given a path.
---@return vcssign.Repo?
function M.active()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' then
    return M.get_by_path(name)
  end
  local cwd = uv.cwd()
  return cwd and M.get_by_path(cwd) or nil
end

---@private
--- Drop a repo from the maps, dispose it and announce it.  Idempotent.
---@param repo vcssign.Repo
function M:_remove(repo)
  local key = base.path_key(repo.root)
  if M._by_root[key] ~= repo then
    return
  end
  M._by_root[key] = nil
  -- Drop references pointing here too: a repository deleted from under the
  -- editor may still be held by buffers that have not noticed yet.
  for ref, held in pairs(M._by_ref) do
    if held == repo then
      M._by_ref[ref] = nil
      -- An attach for this reference may still be resolving: releasing the
      -- reference must cancel it too, or the late callback would resurrect
      -- the very repository being torn down here.
      M._gen[ref] = (M._gen[ref] or 0) + 1
    end
  end
  repo:dispose()
  log.debug('detached %s (%s)', repo.system.name, repo.root)
  util.emit(M._on_detached, repo)
end

---@private
---@param ref string
---@param repo vcssign.Repo
function M:_unbind(ref, repo)
  if M._by_ref[ref] ~= repo then
    return
  end
  M._by_ref[ref] = nil
  repo.refs[ref] = nil
  if next(repo.refs) == nil then
    M:_remove(repo)
  end
end

---@private
---@param ref string
---@param repo vcssign.Repo
---@param cb fun(err: string?, repo: vcssign.Repo?)
function M:_bind(ref, repo, cb)
  local previous = M._by_ref[ref]
  if previous and previous ~= repo then
    -- The buffer moved to another repository.
    M:_unbind(ref, previous)
  end
  repo.refs[ref] = true
  M._by_ref[ref] = repo

  if repo.has_loaded and not repo.is_dirty and not repo.is_updating then
    -- Currently in sync: hand back the cache instead of spawning a command for
    -- every buffer that attaches.  Note this makes `attach` call back
    -- *synchronously* on that path.
    return cb(nil, repo)
  end
  repo:refresh_now(function(err)
    cb(err, repo)
  end)
end

--- Attach `ref` to the repository containing `path`, detecting it if needed.
---
--- `cb(err, repo)` runs once the repository has a populated cache (or the first
--- status run failed) — and synchronously when the cache is already fresh.
--- A `ref` that previously pointed elsewhere is rebound, not leaked.
---@param ref string
---@param path string
---@param cb fun(err: string?, repo: vcssign.Repo?)
function M.attach(ref, path, cb)
  cb = cb or function() end
  M._gen[ref] = (M._gen[ref] or 0) + 1
  local gen, epoch = M._gen[ref], M._epoch

  -- The marker scan spawns nothing, so the common case (a second buffer in a
  -- repository we already track) is answered without touching a VCS binary.
  local detection = registry.detect(path)
  if detection then
    local known = M._by_root[base.path_key(detection.root)]
    if known then
      return M:_bind(ref, known, cb)
    end
  end

  registry.detect_async(path, function(err, system, root)
    if (M._gen[ref] or 0) ~= gen or M._epoch ~= epoch then
      -- `detach`/`_remove`/`dispose_all` ran while detection was in flight, or
      -- this request was superseded by a newer attach: the caller has let go,
      -- so binding now would leak the reference — or outlive the session.
      return cb(string.format('attach cancelled: reference %q was released', ref))
    end
    if err or not root then
      -- Belongs to no repository: drop whatever this ref held before, so a
      -- buffer leaving the repo does not keep it alive.
      M.detach(ref)
      return cb(err or ('no repository for ' .. path))
    end
    local key = base.path_key(root)
    local repo = M._by_root[key]
    if not repo then
      repo = Repo.new(system, root)
      M._by_root[key] = repo
      -- The watcher notices when the repository itself disappears (`rm -rf
      -- .git`, a deleted worktree) and hands it back for teardown.
      repo:on_delete(function(deleted)
        M:_remove(deleted)
      end)
      repo:start()
      log.debug('attached %s at %s', repo.system.name, repo.root)
      util.emit(M._on_attached, repo)
    end
    M:_bind(ref, repo, cb)
  end)
end

--- Reference used by the explicit-command layer (`:Vcssign`, the public API).
---
--- A command is a deliberate request to *use* a repository, so the reference is
--- not released again: the repository (and its watcher) stays for the session,
--- which is what the user asked for.  One reference per *repository* (not per
--- queried path), so asking twice does not accumulate references and two
--- commands for two files never cancel each other's detection.
---@param root string
---@return string
local function cmd_ref(root)
  return 'cmd:' .. base.path_key(base.normalize(root))
end

--- Hold a reference to a repository that is already tracked.
---
--- For consumers that outlive whatever attached the repository: a buffer that
--- keeps a repository attached but no longer has a window of its own (a sign
--- buffer left open, `bufhidden = hide`), so the user may have closed the last
--- file of the repository while the buffer that attached it is still alive.
--- D18 names the buffer reference (`"buf:<bufnr>"`) as a reference holder for
--- exactly this reason.
---
--- No detection and no command: the caller already has the repository.
---@param ref string
---@param repo vcssign.Repo
---@return boolean held  false when the repository is no longer tracked
function M.hold(ref, repo)
  if M._by_root[base.path_key(repo.root)] ~= repo then
    return false
  end
  if M._by_ref[ref] == repo then
    return true
  end
  -- A reference that currently points somewhere else is rebound, not leaked;
  -- its in-flight detection is cancelled for the same reason `attach` cancels.
  M._gen[ref] = (M._gen[ref] or 0) + 1
  local previous = M._by_ref[ref]
  if previous then
    M:_unbind(ref, previous)
  end
  repo.refs[ref] = true
  M._by_ref[ref] = repo
  return true
end

--- Repository for `path`, detecting and attaching it when nothing has yet.
---
--- The command layer cannot assume that a buffer already attached the
--- repository: `:Vcssign toggle` in a fresh session is the first thing that
--- happens, and it has to work.
---@param path string
---@param cb fun(err: string?, repo: vcssign.Repo?)
function M.ensure(path, cb)
  -- A path is not optional here: `base.normalize(nil)` silently produces a
  -- relative path against whatever the cwd happens to be (measured: the
  -- string `v:/null`), and every layer above would then be working on a
  -- directory nobody asked about.  An empty string is a caller mistake too,
  -- but one that can come from user input, so it goes back the normal way.
  if type(path) ~= 'string' or path == '' then
    return cb('no path given')
  end
  local abs = base.normalize(path)
  -- Which repository does the file belong to?  The marker scan answers "the
  -- nearest one", and that matters when a repository is nested inside another
  -- repository that is already attached: `get_by_path` (deliberately, for
  -- lookups) returns the *deepest attached* one, so asking it here would hand
  -- back the outer repository for a file that belongs to the inner one — and
  -- every action would then run against the wrong tree.
  local detection = registry.detect(abs)
  local root = detection and detection.root or abs
  local repo = detection and M.get(root) or nil
  if not repo and not detection then
    -- No marker nearby: fall back to an attached repository containing the
    -- path (a working copy whose marker sits further up, say).
    repo = M.get_by_path(abs)
  end
  if repo then
    -- Already tracked (by a buffer `"buf:<bufnr>"`, or an earlier command).
    -- The reference is taken anyway: D29 promises an explicit command uses this
    -- repository for the rest of the session, and it keeps the repository
    -- alive if the buffer that attached it goes away right afterwards.
    M.hold(cmd_ref(repo.root), repo)
    return cb(nil, repo)
  end
  M.attach(cmd_ref(root), abs, cb)
end

--- Release a reference.  The last reference disposes the repository; any
--- detection this reference still has in flight is cancelled.
---@param ref string
function M.detach(ref)
  M._gen[ref] = (M._gen[ref] or 0) + 1
  local repo = M._by_ref[ref]
  if repo then
    M:_unbind(ref, repo)
  end
end

--- Dispose everything (VimLeavePre): no handle may outlive the session.
function M.dispose_all()
  -- Bumped *first*: an attach still resolving must not create a repository
  -- (with a watcher and a status command) after everything was disposed.
  M._epoch = M._epoch + 1
  for _, root in ipairs(vim.tbl_keys(M._by_root)) do
    local repo = M._by_root[root]
    if repo then
      M:_remove(repo)
    end
  end
  M._by_ref = {}
  M._by_root = {}
end

return M
