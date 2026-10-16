--- The per-buffer attach pipeline: read the baseline, diff it against the
--- buffer and draw the signs, then keep the picture fresh as the file changes.
---
--- Step 5 wires the pipeline but does **not** subscribe to any autocmd yet:
--- `init.lua` / `autocmds.lua` / `plugin/vcssign.vim` are untouched, so the
--- automatic triggers (`BufReadPost` on mount, `TextChanged`/`InsertLeave`
--- beyond `on_lines`, `ColorScheme`) arrive in Step 6.  What is frozen here is
--- the interface those steps will consume and the per-buffer invariants:
---
---   * one attach per buffer, idempotent, keyed by the buffer's path;
---   * every VCS command is spawned through the repository manager and its
---     reference (`attach:<bufnr>`) is released on `detach`;
---   * no vim API runs inside a `textlock` callback — edits only set a flag and
---     go through the debounce, which `vim.schedule`s (D19);
---   * a repository disappearing deactivates the buffer without re-entering the
---     manager from inside its `on_delete` emit.
local api = vim.api
local config = require('vcssign.config')
local base = require('vcssign.vcs.base')
local debounce = require('vcssign.debounce')
local diff = require('vcssign.diff')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local signs = require('vcssign.signs')

local M = {}

--- Per-buffer state.  Deliberately a module table, not `vim.b`: `vim.b` is not
--- reachable from the specs without a buffer-local variable and would make
--- `forget_all()` unable to enumerate it.
---@class vcssign.AttachState
---@field bufnr integer
---@field path string            base.normalize'd absolute path
---@field root string?
---@field rel string?
---@field system vcssign.VcsSystem?
---@field repo vcssign.Repo?
---@field rev string
---@field base_text string?      nil = "no baseline is known" (render nothing)
---@field buf_text string?
---@field hunks vcssign.Hunk[]
---@field tracked boolean?
---@field untracked boolean
---@field attached boolean
---@field enabled boolean
---@field unsubscribe fun()[]
---@field refresh fun()          debounced
---@field refresh_cancel fun()

---@type table<integer, vcssign.AttachState>
M._bufs = {}

--- Release every subscription a state holds.
---@param st vcssign.AttachState
local function unobserve(st)
  for _, unsub in ipairs(st.unsubscribe) do
    unsub()
  end
  st.unsubscribe = {}
end

--- The repository vanished (deleted from under the editor): drop back to
--- "no signs", but do **not** call `manager.detach`.  `repo_manager._remove`
--- already cleared every `_by_ref` entry pointing at this repository, and this
--- runs *inside* its `on_delete` emit — re-entering the manager there would
--- dispose the repo while it is still being announced.
---@param st vcssign.AttachState
local function deactivate(st)
  st.attached = false
  st.repo = nil
  signs.clear(st.bufnr)
  st.refresh_cancel()
  unobserve(st)
end

--- Read the baseline text into `st`, then call `done()`.
---
--- Failure chain: an error from `is_tracked` is "no signs" (and no warning —
--- the stderr contract allows exactly one line, from the runtime spec);
--- `show(rev)` falls back once to `'HEAD'` before giving up.
---@param st vcssign.AttachState
---@param done fun()
local function load_base(st, done)
  st.system.is_tracked(st.root, st.rel, function(terr, tracked)
    if M._bufs[st.bufnr] ~= st then
      return
    end
    if terr then
      st.base_text = nil
      st.hunks = {}
      log.debug('buffer %d: cannot tell whether %s is tracked: %s', st.bufnr, st.rel, terr)
      return done()
    end
    if tracked == false then
      st.tracked, st.untracked = false, true
      -- An untracked file's baseline is the empty file, so every line is added
      -- (rendered as `untracked`, one sign per line).
      st.base_text = config.get().attach_to_untracked and '' or nil
      return done()
    end
    st.tracked, st.untracked = true, false
    ---@param rev string
    ---@param retry boolean
    local function show_with(rev, retry)
      st.system.show(st.root, rev, st.rel, function(err, text)
        if M._bufs[st.bufnr] ~= st then
          return
        end
        if not err then
          st.base_text = text
          return done()
        end
        if retry then
          return show_with('HEAD', false)
        end
        st.base_text = nil
        log.debug('buffer %d: no baseline for %s: %s', st.bufnr, st.rel, err)
        done()
      end)
    end
    show_with(st.rev, st.rev ~= 'HEAD')
  end)
end

--- The only place the pipeline touches the buffer's contents.
---@param st vcssign.AttachState
function M._render(st)
  local buf_lines = api.nvim_buf_get_lines(st.bufnr, 0, -1, false)
  st.buf_text = diff.join(buf_lines)
  if st.base_text == nil then
    signs.clear(st.bufnr)
    st.hunks = {}
    return
  end
  if st.untracked then
    -- One hunk covering the whole file; `signs.place` puts one sign per line.
    st.hunks = {
      {
        added = { start = 1, count = #buf_lines },
        removed = { start = 0, count = 0 },
        type = 'untracked',
      },
    }
  else
    -- `diff.run` reads its defaults from `config.diff`; no opts needed here.
    st.hunks = diff.run(diff.normalize(st.base_text), st.buf_text)
  end
  signs.place(st.bufnr, st.hunks)
end

--- Apply `config.signcolumn` to every window showing `bufnr`.
---
--- `'signcolumn'` is a *window* option: `vim.wo[bufnr]` would not take effect,
--- so the buffer's windows are looked up and each one set.
---@param bufnr integer
local function set_signcolumn(bufnr)
  local sc = config.get().signcolumn
  if sc == false then
    return
  end
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].signcolumn = sc
  end
end

--- Attach `bufnr` (default: the current buffer) to the signs pipeline.
---
--- Returns the state table on success, `nil` when the buffer is not eligible
--- (unnamed, non-file buftype, missing on disk, too long) — or the *existing*
--- state when it is already attached to the same path.
---@param bufnr? integer
---@return vcssign.AttachState? state
function M.attach(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return nil
  end
  if vim.bo[bufnr].buftype ~= '' then
    return nil
  end
  local name = api.nvim_buf_get_name(bufnr)
  if name == '' then
    return nil
  end
  local path = base.normalize(name)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil
  end
  local line_count = api.nvim_buf_line_count(bufnr)
  if line_count > config.get().max_file_length then
    log.debug('buffer %d: %d lines is over max_file_length', bufnr, line_count)
    return nil
  end

  -- Idempotent: a second attach for the same path must not spawn anything.
  local prev = M._bufs[bufnr]
  if prev then
    if prev.path == path then
      return prev
    end
    -- `:saveas` / `:e` renamed the buffer onto another file.
    M.detach(bufnr)
  end

  ---@type vcssign.AttachState
  local st = {
    bufnr = bufnr,
    path = path,
    rev = config.get().rev,
    hunks = {},
    untracked = false,
    attached = false,
    enabled = true,
    unsubscribe = {},
  }
  -- The debounced refresh.  `debounce_trailing` dispatches through
  -- `vim.schedule`, so the callbacks below stay inside the main loop (D19).
  st.refresh, st.refresh_cancel = debounce.debounce_trailing({
    timeout = function()
      return config.get().update_debounce_ms
    end,
  }, function()
    if M._bufs[bufnr] == st then
      M.refresh(bufnr)
    end
  end)

  -- Stored *before* the asynchronous chain: `manager.attach` may answer
  -- synchronously, and the callback below must find this state.
  M._bufs[bufnr] = st

  -- Put the column in place before any command runs, so the window does not
  -- jump width when the signs finally arrive.
  set_signcolumn(bufnr)
  signs.define_highlights()

  local ref = 'attach:' .. bufnr
  manager.attach(ref, path, function(err, repo)
    -- Superseded by a newer attach, or detached while detection was in flight.
    if M._bufs[bufnr] ~= st then
      return
    end
    if not repo then
      st.enabled = false
      -- `log.debug`, not `log.warn`: the stderr contract allows one line.
      log.debug('buffer %d: %s', bufnr, err or 'no repository')
      return
    end
    if not manager.hold(ref, repo) then
      st.enabled = false
      log.debug('buffer %d: repository is no longer tracked', bufnr)
      return
    end
    st.repo, st.root, st.system = repo, repo.root, repo.system
    st.rev = config.get().rev
    st.rel = base.relpath(path, repo.root)
    if not st.rel then
      log.debug('buffer %d: %s is outside %s', bufnr, path, repo.root)
      return
    end
    st.attached = true
    st.unsubscribe = {
      repo:on_update(function()
        M.mark_dirty(bufnr)
      end),
      repo:on_error(function(e)
        log.debug('buffer %d: %s', bufnr, e)
      end),
      repo:on_delete(function()
        deactivate(st)
      end),
    }
    load_base(st, function()
      M._render(st)
    end)
  end)

  api.nvim_buf_attach(bufnr, false, {
    -- `on_lines` / `on_reload` run under `textlock`: no vim API, no commands,
    -- not even reading the buffer.  Only the dirty flag moves here.
    on_lines = function()
      M.mark_dirty(bufnr)
    end,
    on_reload = function()
      M.mark_dirty(bufnr)
    end,
    on_detach = function()
      M.detach(bufnr)
    end,
  })

  return st
end

--- Note that the buffer changed and schedule the debounced re-render.
---@param bufnr integer
function M.mark_dirty(bufnr)
  local st = M._bufs[bufnr]
  if not st or not st.enabled or not st.attached then
    return
  end
  st.refresh()
end

--- Re-read the baseline, re-diff and re-draw, right now.
---@param bufnr integer
---@param cb? fun(err: string?)
function M.refresh(bufnr, cb)
  local st = M._bufs[bufnr]
  if not st or not st.attached or not st.repo then
    if cb then
      cb('not attached')
    end
    return
  end
  load_base(st, function()
    if M._bufs[bufnr] ~= st or not st.attached then
      if cb then
        cb('not attached')
      end
      return
    end
    M._render(st)
    if cb then
      cb(nil)
    end
  end)
end

--- Detach one buffer: clear its signs, cancel its debounce, drop its
--- subscriptions and release its repository reference.
---@param bufnr integer
function M.detach(bufnr)
  local st = M._bufs[bufnr]
  if not st then
    return
  end
  signs.clear(bufnr)
  st.refresh_cancel()
  unobserve(st)
  M._bufs[bufnr] = nil
  manager.detach('attach:' .. bufnr)
end

---@param bufnr integer
---@return vcssign.AttachState?      the state table itself, not a copy
function M.state(bufnr)
  return M._bufs[bufnr]
end

---@param bufnr integer
---@return vcssign.Hunk[]
function M.hunks(bufnr)
  local st = M._bufs[bufnr]
  return st and st.hunks or {}
end

---@param bufnr integer
---@return string?
function M.root(bufnr)
  local st = M._bufs[bufnr]
  return st and st.root
end

---@param bufnr integer
---@return vcssign.VcsSystem?
function M.system(bufnr)
  local st = M._bufs[bufnr]
  return st and st.system
end

---@param bufnr integer
---@return vcssign.VcsCaps?
function M.capabilities(bufnr)
  local st = M._bufs[bufnr]
  return st and st.system and st.system.capabilities or nil
end

---@return integer  how many buffers are attached
function M.count()
  local n = 0
  for _, st in pairs(M._bufs) do
    if st.attached then
      n = n + 1
    end
  end
  return n
end

--- Drop every buffer's state and handling, without disposing repositories.
---
--- For `VimLeavePre` (Step 6): the process is going away, so the manager's
--- `dispose_all` runs on the same event, but `forget_all` itself must not touch
--- repositories — a buffer may be forgotten while its repository is still kept
--- alive by a command reference.
function M.forget_all()
  for _, st in pairs(M._bufs) do
    signs.clear(st.bufnr)
    st.refresh_cancel()
    unobserve(st)
  end
  M._bufs = {}
end

return M
