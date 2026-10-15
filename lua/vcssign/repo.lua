--- One repository's live runtime: status cache, filesystem watching and the
--- debounced, serialised refresh pipeline.
---
--- The split matters: filesystem events and autocmds only ever *mark* the repo
--- dirty, and VCS commands are spawned in exactly one place (`_do_refresh`).
--- That is what makes "10 rapid writes produce at most 2 `git status` runs"
--- hold, and what keeps concurrent refreshes impossible.
--- See impl/init/02-repo-runtime.md §3.
local config = require('vcssign.config')
local debounce = require('vcssign.debounce')
local log = require('vcssign.log')
local util = require('vcssign.util')
local base = require('vcssign.vcs.base')

local uv = vim.uv

--- libuv cannot watch a directory recursively on Linux (inotify has no such
--- mode), so there the metadata watch degrades to non-recursive.  The signal
--- that matters most — `.git/index` — is a *direct child* of `.git`, so it is
--- still caught (measured: `git add` emits `index.lock` + `index` renames).
local RECURSIVE_FS_EVENT = uv.os_uname().sysname ~= 'Linux'

local M = {}
-- `M` doubles as the module and the class: instances are plain tables whose
-- metatable points back here.
M.__index = M

---@class vcssign.Repo
---@field system vcssign.VcsSystem
---@field root string
---@field marker_path string   absolute path of `.git` / `.svn`
---@field metadata_path string  the *watched* metadata directory: `marker_path`, or
---                             the `gitdir:` target for a worktree/submodule.
---                             Set by `start()`.
---@field status vcssign.StatusEntry[]  last *successful* status list
---@field status_map table<string, vcssign.StatusEntry>  absolute path -> entry
---@field refs table<string, true>  reference tokens currently holding this repo
---@field is_dirty boolean
---@field is_updating boolean
---@field has_pending boolean   a refresh was requested while one was running
---@field is_deleted boolean    the repository vanished / was disposed
---@field has_loaded boolean    at least one successful status run happened
---@field error_count integer   consecutive failures (backoff exponent)
---@field last_error string?
---@field fs_handles table<string, uv.uv_fs_event_t>
---@field fs_handle_pool uv.uv_fs_event_t[]
---@field watch_paths table<string, true>

---@param path string
---@return boolean
local is_dir = util.is_dir

---@param list function[]
---@param fn function
---@return fun() unsubscribe
local subscribe = util.subscribe

--- A new, empty runtime for `root`.  Nothing is spawned or watched yet; the
--- manager calls `:start()`, actions call `:refresh_now()`.
---@param system vcssign.VcsSystem
---@param root string
---@return vcssign.Repo
function M.new(system, root)
  local self = setmetatable({}, M)
  self.system = system
  self.root = base.normalize(root)
  self.marker_path = vim.fs.normalize(vim.fs.joinpath(self.root, system.keyfile))
  self.status = {}
  self.status_map = {}
  self.refs = {}
  self.is_dirty = true -- the first refresh is always wanted
  self.is_updating = false
  self.has_pending = false
  self.is_deleted = false
  self.has_loaded = false
  self.error_count = 0
  self.last_error = nil
  self.fs_handles = {}
  self.fs_handle_pool = {}
  self.watch_paths = {}
  self._waiters = {}
  self._on_update = {}
  self._on_error = {}
  self._on_delete = {}
  self._refresh_debounced, self._refresh_cancel = debounce.debounce_trailing({
    timeout = function()
      return config.get().update_debounce_ms
    end,
  }, function()
    self:_do_refresh()
  end)
  return self
end

-- ▏ status cache ──────────────────────────────────────────────────────────────

--- The cached status list.  Not a copy: the list is replaced wholesale on every
--- successful run, so holding on to it is safe and cheap.
---@return vcssign.StatusEntry[]
function M:entries()
  return self.status
end

--- Cached entry for an *already normalised, absolute* path (the paths in
--- `self.status` are exactly that, so the renderer pays no normalisation cost).
---@param path string
---@return vcssign.StatusEntry?
function M:get_entry(path)
  return self.status_map[base.path_key(path)]
end

--- Status of one file, or nil when the VCS reports nothing for it.
---@param path string
---@return vcssign.FileStatus?
function M:get_status(path)
  local entry = self.status_map[base.path_key(base.normalize(path))]
  return entry and entry.status or nil
end

---@param fn fun(repo: vcssign.Repo)
---@return fun() unsubscribe
function M:on_update(fn)
  return subscribe(self._on_update, fn)
end

---@param fn fun(err: string, repo: vcssign.Repo)
---@return fun() unsubscribe
function M:on_error(fn)
  return subscribe(self._on_error, fn)
end

---@param fn fun(repo: vcssign.Repo)
---@return fun() unsubscribe
function M:on_delete(fn)
  return subscribe(self._on_delete, fn)
end

-- ▏ refresh pipeline ──────────────────────────────────────────────────────────

--- Note a change and coalesce a refresh behind the debounce window.
function M:mark_dirty()
  if self.is_deleted then
    return
  end
  self.is_dirty = true
  self._refresh_debounced()
end

--- Debounced refresh.  `cb(err, entries)` fires once the run this request
--- belongs to has finished; requests inside the same window share one run.
---
--- A callback registered while a run is already in flight is served by that
--- run: its snapshot may predate the request, so treat `entries` as "at
--- least this fresh" — `on_update` fires again when the follow-up run lands.
---@param cb? fun(err: string?, entries: vcssign.StatusEntry[]?)
function M:refresh(cb)
  if self.is_deleted then
    if cb then
      cb('repository deleted: ' .. self.root, self.status)
    end
    return
  end
  if cb then
    self._waiters[#self._waiters + 1] = cb
  end
  self:mark_dirty()
end

--- Refresh right away, skipping the debounce window: used for the first load
--- after attach and after an explicit action, where somebody is waiting.
---
--- Also restarts the *backoff* (a manual attempt should retry sooner than one
--- that is already 30s into a failure streak).  It deliberately does **not**
--- clear `last_error`: that field doubles as the "this streak was already
--- reported" marker, so a manual retry of a known-broken repository does not
--- repeat the warning (the caller's own `cb` gets the error).
---@param cb? fun(err: string?, entries: vcssign.StatusEntry[]?)
function M:refresh_now(cb)
  if self.is_deleted then
    if cb then
      cb('repository deleted: ' .. self.root, self.status)
    end
    return
  end
  if cb then
    self._waiters[#self._waiters + 1] = cb
  end
  self.error_count = 0
  if vim.in_fast_event() then
    vim.schedule(function()
      self:_do_refresh()
    end)
  else
    self:_do_refresh()
  end
end

---@private
function M:_do_refresh()
  if self.is_deleted then
    return self:_flush_waiters('repository deleted: ' .. self.root)
  end
  if self.is_updating then
    -- Serialise rather than queue: the running pass runs once more when it
    -- finishes, so no request is lost (gitsigns' `throttle_async(schedule =
    -- true)` semantics, implemented with callbacks instead of coroutines).
    self.has_pending = true
    return
  end
  -- Set *before* the command runs.  `system.status` is normally asynchronous,
  -- but an unsupported capability or a rejected file list calls back
  -- synchronously (see impl/init/01-vcs-adapter.md §3), and a flag set
  -- afterwards would be cleared by that synchronous callback and then re-set by
  -- the real one — two overlapping refreshes.
  -- This run supersedes a debounce that is still armed: without this, a
  -- `refresh_now` landing inside the window would be answered twice (once
  -- here, once when the window closes).  Safe to call from the debounced
  -- callback itself: the timer has fired by then, and `cancel` merely
  -- closes it and invalidates the generation.
  self._refresh_cancel()
  self.is_updating = true
  local done = false
  ---@param err string?
  ---@param entries vcssign.StatusEntry[]?
  local function finish(err, entries)
    if done then
      return
    end
    done = true
    self.is_updating = false
    -- The repository may have been disposed while the command was running
    -- (its marker vanished).  Its waiters were already released by
    -- `_mark_deleted`, and arming a retry timer now would put a live handle on
    -- a terminal object.
    if self.is_deleted then
      return
    end
    if err then
      self:_on_refresh_error(err)
    else
      self:_apply_status(entries or {})
    end
    self:_flush_waiters(err)
    if self.has_pending then
      self.has_pending = false
      self:_do_refresh()
    end
  end
  -- `pcall` the *call* as well as the result: an adapter that raises instead of
  -- calling back would otherwise leave `is_updating` set forever and wedge the
  -- pipeline.  `finish` is idempotent, so a synchronous callback followed by a
  -- throw is still handled exactly once.
  local ok, thrown = pcall(self.system.status, self.root, finish)
  if not ok then
    finish(string.format('status command failed: %s', tostring(thrown)))
  end
end

---@private
---@param entries vcssign.StatusEntry[]
function M:_apply_status(entries)
  local new_map = {}
  for _, entry in ipairs(entries) do
    new_map[base.path_key(entry.path)] = entry
  end

  -- Compare before storing, so an unchanged status does not wake the renderer.
  -- Comparing the *maps* rather than the arrays keeps this insensitive to the
  -- order the VCS happened to print the entries in.
  --
  -- The first successful run always notifies, otherwise a *clean* repository
  -- would never be drawn (`{} == {}` and the sidebar would stay empty).
  local changed = not self.has_loaded or not vim.deep_equal(self.status_map, new_map)

  self.status = entries
  self.status_map = new_map
  self.is_dirty = false
  self.error_count = 0
  self.last_error = nil
  self:_cancel_retry()
  self.has_loaded = true

  if changed then
    log.debug('%s: %d status entries', self.root, #entries)
    util.emit(self._on_update, self)
  end
end

---@private
---@param err string
function M:_on_refresh_error(err)
  self.error_count = self.error_count + 1
  -- One warning per failure streak, not one per retry.
  if self.last_error == nil then
    log.warn('%s: %s', self.root, err)
  end
  self.last_error = err
  util.emit(self._on_error, err, self)
  self:_schedule_retry()
end

---@private
function M:_schedule_retry()
  if self.is_deleted then
    return
  end
  local cfg = config.get()
  local delay_ms = cfg.retry_delay_ms
  if not delay_ms or delay_ms <= 0 then
    return
  end
  self:_cancel_retry()
  local delay = math.min(delay_ms * 2 ^ (self.error_count - 1), cfg.retry_max_ms or delay_ms)
  local timer = uv.new_timer()
  if not timer then
    return
  end
  self._retry_timer = timer
  log.debug('%s: retrying in %dms', self.root, delay)
  timer:start(delay, 0, vim.schedule_wrap(function()
    local armed = self._retry_timer == timer
    if armed then
      self._retry_timer = nil
    end
    timer:stop()
    if not timer:is_closing() then
      timer:close()
    end
    -- `_cancel_retry` may have closed the timer while this callback was
    -- already queued (a successful run landed between firing and this
    -- tick): a cancelled retry must not spawn another run.
    if armed and not self.is_deleted then
      self:_do_refresh()
    end
  end))
end

---@private
function M:_cancel_retry()
  local timer = self._retry_timer
  if not timer then
    return
  end
  self._retry_timer = nil
  timer:stop()
  if not timer:is_closing() then
    timer:close()
  end
end

--- Call a refresh callback, isolating failures: a broken callback must not
--- leave the pipeline half-finished.
---
--- The isolation also means an assertion raised inside a callback is logged
--- instead of propagated, so tests must record their result and assert in the
--- case body rather than inside the callback.
---@param cb fun(err: string?, entries: vcssign.StatusEntry[]?)
---@param err string?
function M:_call_waiter(cb, err)
  local ok, cb_err = pcall(cb, err, self.status)
  if not ok then
    log.error('refresh callback failed: %s', tostring(cb_err))
  end
end

---@private
---@param err string?
function M:_flush_waiters(err)
  if #self._waiters == 0 then
    return
  end
  -- Swap first: a waiter that calls `refresh()` again must land in the next
  -- round, not in the list being iterated.
  local waiters = self._waiters
  self._waiters = {}
  for _, cb in ipairs(waiters) do
    self:_call_waiter(cb, err)
  end
end

-- ▏ filesystem watching ───────────────────────────────────────────────────────

--- Start watching for changes.  Called once by the manager for a new repo.
function M:start()
  if self.is_deleted or not config.get().watch then
    return
  end
  self:_init_watch()
end

---@private
function M:_init_watch()
  -- The metadata directory may not be the keyfile: in a git worktree (or a
  -- submodule) `.git` is a *file* pointing outside the worktree, and that
  -- target is where the index actually lives.
  local metadata = self.system.metadata_dir and self.system.metadata_dir(self.root) or nil
  self.metadata_path = metadata or self.marker_path
  -- Metadata first: the child-directory loop below would otherwise claim the
  -- marker with a non-recursive watch and the index would still be seen (it is
  -- a direct child) but nothing deeper would be.
  self:_watch(self.metadata_path, RECURSIVE_FS_EVENT)
  self:_watch(self.root, false)
  -- Depth 1 only.  Watching every directory of a large repository costs one
  -- handle each (and on Linux there is no recursive mode to do it for us), but
  -- *not* watching a directory one level down would mean most real edits —
  -- anything below the root — go unnoticed.
  for name, kind in vim.fs.dir(self.root) do
    if kind == 'directory' then
      self:_watch(vim.fs.joinpath(self.root, name), false)
    end
  end
end

---@private
---@param path string
---@param recursive boolean
function M:_watch(path, recursive)
  path = vim.fs.normalize(path)
  if self.watch_paths[path] or not is_dir(path) then
    return
  end
  local handle = table.remove(self.fs_handle_pool)
  if not handle then
    handle = uv.new_fs_event()
  end
  if not handle then
    log.debug('no fs_event handle available for %s', path)
    return
  end
  -- libuv callbacks run in a fast event context (verified), so everything the
  -- handler touches has to be dispatched to the main loop first.
  local ok, err = handle:start(path, recursive and { recursive = true } or {}, vim.schedule_wrap(function(e, filename, events)
    self:_on_fs_event(path, e, filename, events)
  end))
  if not ok then
    log.debug('cannot watch %s: %s', path, tostring(err))
    if not handle:is_closing() then
      handle:close()
    end
    return
  end
  self.fs_handles[path] = handle
  self.watch_paths[path] = true
  log.debug('watching %s (recursive=%s)', path, tostring(recursive))
end

---@private
---@param path string
function M:_unwatch(path)
  local handle = self.fs_handles[path]
  if not handle then
    return
  end
  self.fs_handles[path] = nil
  self.watch_paths[path] = nil
  handle:stop()
  if not handle:is_closing() then
    self.fs_handle_pool[#self.fs_handle_pool + 1] = handle
  end
end

---@private
function M:_stop_watching()
  for path, handle in pairs(self.fs_handles) do
    handle:stop()
    if not handle:is_closing() then
      handle:close()
    end
    self.fs_handles[path] = nil
  end
  for _, handle in ipairs(self.fs_handle_pool) do
    if not handle:is_closing() then
      handle:close()
    end
  end
  self.fs_handle_pool = {}
  self.watch_paths = {}
end

---@private
---@param watch_path string   the directory the handle was started on
---@param err string?
---@param filename string?
---@param events { change: boolean?, rename: boolean? }?
function M:_on_fs_event(watch_path, err, filename, events)
  if self.is_deleted then
    return
  end
  if err then
    -- A dead handle would silently stop reporting changes for this directory
    -- for the rest of the repository's life; drop it instead and let the watch
    -- set pick the directory up again if it reappears.
    log.warn('%s: filesystem watch error on %s: %s', self.root, watch_path, err)
    self:_unwatch(watch_path)
    return
  end
  -- The repository is gone: either its root or its metadata directory.  Note
  -- `.git` may legitimately be a *file* (worktree/submodule), so this checks for
  -- existence rather than for a directory.
  if not is_dir(self.root) or uv.fs_stat(self.marker_path) == nil then
    log.debug('repository gone: %s', self.root)
    return self:_mark_deleted()
  end
  self:_sync_watch_set(watch_path, filename, events)
  -- A status run can rewrite `.git/index`; an event caused by our own command
  -- must not queue another run.  (`--no-optional-locks` already prevents the
  -- rewrite in practice — this is the belt to that pair of braces.)
  -- Not dropped outright though: a `git add` that lands entirely inside the
  -- status run would be lost forever.  Note it as pending instead — the run
  -- in flight picks it up with exactly one more pass, and the debounce stays
  -- unarmed, so a VCS that *did* rewrite its metadata on every status
  -- command cannot feed itself a loop.
  if self.is_updating and watch_path == self.metadata_path then
    log.debug('metadata event during an update noted: %s', watch_path)
    self.is_dirty = true
    self.has_pending = true
    return
  end
  self:mark_dirty()
end

---@private
--- Keep the watch set in step with the tree: a directory that appears directly
--- under the root gets its own watch, a deleted one is dropped.
---@param watch_path string
---@param filename string?
---@param events { change: boolean?, rename: boolean? }?
function M:_sync_watch_set(watch_path, filename, events)
  if watch_path ~= self.root or not events or not events.rename or not filename then
    return
  end
  -- `filename` uses the platform separator on Windows (`sub\deep`).
  local child = vim.fs.normalize(vim.fs.joinpath(watch_path, filename))
  if child == self.root then
    return
  end
  if is_dir(child) then
    self:_watch(child, false)
  elseif self.watch_paths[child] then
    self:_unwatch(child)
  end
end

-- ▏ teardown ──────────────────────────────────────────────────────────────────

---@private
--- Stop refreshing, watching and retrying, and tell the manager.  Idempotent.
function M:_mark_deleted()
  if self.is_deleted then
    return
  end
  self.is_deleted = true
  self:_cancel_retry()
  -- Otherwise a pending debounce would fire a refresh against a dead repo.
  self._refresh_cancel()
  self:_stop_watching()
  -- Callers parked on a refresh must not hang: release them with the reason.
  -- Done before `_on_delete` because the manager disposes (and so clears the
  -- waiter list) from that handler.
  self:_flush_waiters('repository deleted: ' .. self.root)
  util.emit(self._on_delete, self)
end

--- Release every handle and subscriber.  Terminal: the manager drops the repo
--- from its maps right after this, and `impl/init/02-repo-runtime.md` §5.4
--- asserts that no `uv_fs_event_t`/`uv_timer_t` survives it.
---
--- The manager is normally the caller, but calling it directly is still safe:
--- `_mark_deleted` emits `on_delete`, which is exactly how the manager learns
--- about it (and `_remove` is idempotent).
function M:dispose()
  self:_mark_deleted()
  self._waiters = {}
  self._on_update = {}
  self._on_error = {}
  self._on_delete = {}
  self.refs = {}
end

return M
