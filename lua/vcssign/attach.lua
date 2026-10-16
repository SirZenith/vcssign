--- The per-buffer attach pipeline: read the baseline, diff it against the
--- buffer and draw the signs, then keep the picture fresh as the file changes.
---
--- Step 6 wires the automatic triggers in `autocmds.lua`: `BufReadPost` /
--- `BufEnter` attach a buffer, `BufWritePost` and `FocusGained` refresh it,
--- `BufDelete` / `BufWipeout` and `nvim_buf_attach`'s own `on_detach` detach
--- it, `VimLeavePre` forgets everything.  It also adds the per-buffer on/off
--- switch (`M.toggle`, `:Vcssign toggle`) and, in Step 8, the buffer-local
--- default keymaps (`vcssign.keymap`, §4) — installed once the buffer has a
--- repository, removed on detach.  Step 7 adds the second layer: for
--- git the staged changes (`HEAD`..*index*) are rendered into
--- `vcssign_signs_staged` from a second baseline, filtered so no line is
--- painted twice (D40).  Step 10 adds the two opt-in previews, and they are
--- rendered here: the inline word diff (`vcssign.worddiff`) inside the changed
--- lines and the deleted-line preview (`vcssign.preview`) as virtual lines.
--- What this module owns is the per-buffer invariant set:
---
---   * one attach per buffer, idempotent, keyed by the buffer's path;
---   * every VCS command is spawned through the repository manager and its
---     reference (`attach:<bufnr>`) is released on `detach`;
---   * no vim API runs inside a `textlock` callback — edits only set a flag and
---     go through the debounce, which `vim.schedule`s (D19);
---   * a repository disappearing deactivates the buffer without re-entering the
---     manager from inside its `on_delete` emit.
local api = vim.api
local blame = require('vcssign.blame')
local config = require('vcssign.config')
local base = require('vcssign.vcs.base')
local debounce = require('vcssign.debounce')
local diff = require('vcssign.diff')
local hunk = require('vcssign.hunk')
local keymap = require('vcssign.keymap')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local preview = require('vcssign.preview')
local signs = require('vcssign.signs')
local worddiff = require('vcssign.worddiff')

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
---@field head_text string?      `HEAD` for the staged layer; nil = no staged layer
---@field buf_text string?
---@field hunks vcssign.Hunk[]             worktree layer (index -> buffer)
---@field hunks_staged vcssign.Hunk[]      staged layer (HEAD -> buffer), git only
---@field tracked boolean?
---@field untracked boolean
---@field attached boolean
---@field enabled boolean       false = the pipeline found nothing to diff against
---@field shown boolean         the user's sign switch (`M.toggle`)
---@field ready boolean         false until the first attach chain has answered
---@field waiters fun(err: string?, st: vcssign.AttachState?)[]  see `M.ready`
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

--- Answer the waiters `M.ready` parked on this state.
---
--- Called exactly once per attach chain: with `err` when the buffer can never be
--- diffed (no repository, no relative path, the repository gone), and without it
--- once the first render has happened.  The callbacks run in the main loop —
--- `manager.attach`'s answer and `show`'s both arrive there — so they may use the
--- vim API.
---@param st vcssign.AttachState
---@param err? string
local function settle(st, err)
  if st.ready then
    return
  end
  st.ready = true
  local waiters = st.waiters
  st.waiters = {}
  for _, cb in ipairs(waiters) do
    -- A waiter that throws must not take the attach chain down with it: it is a
    -- caller's continuation, not part of the pipeline.
    local ok, werr = pcall(cb, err, err and nil or st)
    if not ok then
      log.error('buffer %d: a ready waiter failed: %s', st.bufnr, werr)
    end
  end
end

--- Everything vcssign draws in `bufnr`: the two sign layers, the inline word
--- diff and the deleted-line preview.  The hunk preview window is closed too —
--- it describes a hunk that is about to be redrawn.
---@param bufnr integer
local function clear_layers(bufnr)
  signs.clear(bufnr)
  worddiff.clear(bufnr)
  preview.clear(bufnr)
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
  clear_layers(st.bufnr)
  blame.detach(st.bufnr)
  st.refresh_cancel()
  unobserve(st)
  settle(st, 'the repository is gone')
end

--- Whether this buffer gets a staged layer at all: only git has a staging
--- area, and only when the buffer is compared against it — with any other
--- `rev` the two baselines would produce the same picture on the same lines.
---@param st vcssign.AttachState
---@return boolean
local function wants_staged(st)
  return st.rev == 'index' and st.system.capabilities.staged_signs == true
end

--- Read `HEAD` into `st.head_text` — the staged layer's baseline — then call
--- `done()`.
---
--- No `HEAD` yet (a repository born in this session, with a staged file) is
--- not a failure: the staged layer's baseline is the empty file, exactly like
--- an untracked file's, and every line reads as staged-added.
---@param st vcssign.AttachState
---@param done fun()
local function load_head(st, done)
  if not wants_staged(st) then
    st.head_text = nil
    return done()
  end
  st.system.show(st.root, 'HEAD', st.rel, function(err, text)
    if M._bufs[st.bufnr] ~= st then
      return
    end
    if err then
      st.head_text = ''
      log.debug('buffer %d: no HEAD for %s: %s', st.bufnr, st.rel, err)
    else
      st.head_text = text
    end
    done()
  end)
end

--- Read the baseline text into `st`, then call `done()`.
---
--- Failure chain: an error from `is_tracked` is "no signs" (and no warning —
--- the stderr contract allows exactly one line, from the runtime spec);
--- `show(rev)` falls back once to `'HEAD'` before giving up.
---@param st vcssign.AttachState
---@param done fun()
local function load_base(st, done)
  -- Both baselines are re-read together (they have to describe the same
  -- moment), so a refresh cannot leave an older `head_text` behind: every
  -- branch below either sets it or leaves it nil.
  st.head_text = nil
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
          return load_head(st, done)
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
  st.hunks, st.hunks_staged = {}, {}
  if st.base_text == nil then
    clear_layers(st.bufnr)
    return
  end
  -- Both previews read the same baseline as the signs, so it is split once.
  local base_lines = diff.split(diff.normalize(st.base_text))
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
    if st.head_text ~= nil then
      -- The staged layer (D40): what `HEAD`..buffer adds on top of what the
      -- worktree layer already paints.  `filter_common` drops the regions the
      -- two layers would both claim, so a line is never painted twice — a hunk
      -- holding unstaged changes is not staged anymore.
      st.hunks_staged = hunk.filter_common(
        diff.run(diff.normalize(st.head_text), st.buf_text),
        st.hunks
      ) or {}
    end
  end
  if st.shown then
    signs.place(st.bufnr, st.hunks)
    signs.place(st.bufnr, st.hunks_staged, { staged = true })
    -- Step 10: the two opt-in previews are part of the same render.  They are
    -- cleared and redrawn together with the signs, so they can never describe a
    -- hunk the signs do not have anymore.
    worddiff.render(st.bufnr, st.hunks, base_lines, buf_lines)
    preview.render_deleted(st.bufnr, st.hunks, base_lines, buf_lines)
  else
    -- The switch is off: keep `st.hunks` (the accessors must stay truthful)
    -- but leave the column empty.
    clear_layers(st.bufnr)
  end
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
    shown = true,
    ready = false,
    waiters = {},
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
  worddiff.define_highlights()
  preview.define_highlights()
  blame.define_highlights()

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
      return settle(st, err or 'no repository')
    end
    if not manager.hold(ref, repo) then
      st.enabled = false
      log.debug('buffer %d: repository is no longer tracked', bufnr)
      return settle(st, 'the repository is no longer tracked')
    end
    st.repo, st.root, st.system = repo, repo.root, repo.system
    st.rev = config.get().rev
    st.rel = base.relpath(path, repo.root)
    if not st.rel then
      log.debug('buffer %d: %s is outside %s', bufnr, path, repo.root)
      return settle(st, string.format('%s is outside %s', path, repo.root))
    end
    st.attached = true
    -- Keys first, so `]c` works the moment the buffer has a repository even if
    -- the baseline is still in flight; navigation asks for the hunks when it
    -- runs, not when the mapping is installed.
    keymap.attach(bufnr)
    blame.attach(bufnr)
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
      settle(st)
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
  if not st or not st.enabled or not st.attached or not st.shown then
    return
  end
  st.refresh()
end

--- Turn this buffer's signs on or off (what `:Vcssign toggle` does).
---
--- Off clears the column and stops the refresh work; on re-renders from a
--- freshly read baseline.  The pipeline stays attached either way, so the
--- switch costs nothing but a redraw and the repository reference survives it.
---@param bufnr? integer
---@return boolean? shown  the new state, nil when the buffer cannot be attached
function M.toggle(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local st = M._bufs[bufnr] or M.attach(bufnr)
  if not st then
    return nil
  end
  st.shown = not st.shown
  if st.shown then
    -- Re-read the baseline: edits made while the switch was off returned early
    -- from `mark_dirty`, so `st.hunks` may be stale.
    if st.attached then
      M.refresh(bufnr)
    else
      M._render(st)
    end
  else
    clear_layers(bufnr)
  end
  return st.shown
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

--- Run `cb(err, st)` once `bufnr`'s baseline is known.
---
--- The action layer needs this: a hunk action runs *after* the signs exist, but
--- `:Vcssign stage_hunk` can be the first thing typed in a session, when the
--- buffer is still loading its baseline.  `attach` is idempotent, so asking for
--- an unattached buffer starts the pipeline instead of failing; the wait itself
--- is a waiter list rather than a poll, so nothing here needs a timer.
---@param bufnr integer
---@param cb fun(err: string?, st: vcssign.AttachState?)
function M.ready(bufnr, cb)
  bufnr = bufnr or api.nvim_get_current_buf()
  local st = M._bufs[bufnr] or M.attach(bufnr)
  if not st then
    return cb(string.format('buffer %d cannot be attached', bufnr), nil)
  end
  if not st.ready then
    st.waiters[#st.waiters + 1] = cb
    return
  end
  if not st.attached then
    -- Either the pipeline found no repository (`enabled` is false) or the
    -- repository went away after it did; both mean "nothing to act on".
    return cb(string.format('no repository for %s', st.path), nil)
  end
  cb(nil, st)
end

--- Detach one buffer: clear its signs, cancel its debounce, drop its
--- subscriptions and release its repository reference.
---@param bufnr integer
function M.detach(bufnr)
  local st = M._bufs[bufnr]
  if not st then
    return
  end
  clear_layers(bufnr)
  st.refresh_cancel()
  unobserve(st)
  settle(st, 'the buffer was detached')
  keymap.detach(bufnr)
  blame.detach(bufnr)
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

--- Every attached buffer, in buffer-number order (the `FocusGained` sweep).
---@return integer[]
function M.buffers()
  local out = {}
  for bufnr, st in pairs(M._bufs) do
    if st.attached then
      out[#out + 1] = bufnr
    end
  end
  table.sort(out)
  return out
end

--- Re-read every attached buffer's baseline.  This is the `FocusGained`
--- fallback: the index may have moved while another program held the focus and
--- Windows fs events are not guaranteed to arrive.
function M.refresh_all()
  for _, bufnr in ipairs(M.buffers()) do
    M.refresh(bufnr)
  end
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
    clear_layers(st.bufnr)
    blame.detach(st.bufnr)
    st.refresh_cancel()
    unobserve(st)
    settle(st, 'the signs were dropped')
  end
  M._bufs = {}
end

return M
