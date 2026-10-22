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
---@field base_stamp string?   the adapter's baseline key when `base_text` was read
---@field render_key? { tick: integer, base: string?, head: string?, shown: boolean, conf: string }
---                             what the last render was made from (`M._render`'s
---                             short-circuit, perf P0-4); nil = never rendered
---@field hunks vcssign.Hunk[]             worktree layer (index -> buffer)
---@field hunks_staged vcssign.Hunk[]      staged layer (HEAD -> buffer), git only
---@field tracked boolean?
---@field untracked boolean
---@field added boolean?      svn: scheduled for addition (no BASE node)
---@field ignored boolean?     the VCS ignores this path: no baseline, no signs (D49)
---@field attached boolean
---@field abandoned boolean    the repository went away; a later `attach` rebuilds
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
  -- Terminal, but recoverable: `M.attach` rebuilds an abandoned state
  -- instead of handing this one back, so the buffer can be picked up again
  -- if the repository comes back.  It is *not* `M.detach`: this runs inside
  -- `repo_manager`'s `on_delete` emit, where re-entering the manager would
  -- dispose the repository that is still being announced.
  st.abandoned = true
  st.repo = nil
  clear_layers(st.bufnr)
  keymap.detach(st.bufnr)
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

--- The adapter's free "did the baseline store move" key, or nil when this
--- adapter has none (a VCS without `baseline_stamp` keeps re-reading).
---@param st vcssign.AttachState
---@return string?
local function stamp_of(st)
  -- The pcall lives in `base.stamp` so the blame cache asks the same question
  -- the same way: an adapter that raises degrades to "no fingerprint" (re-read,
  -- never skip) instead of wedging every refresh.
  return base.stamp(st.system, st.root)
end

--- Whether the baseline `st` holds may be out of date now.
---
--- Every trigger that reaches the debounce means "ask again", not "the index
--- moved": a buffer edit cannot touch the baseline at all, and an fs event or
--- the probe behind `FocusGained` usually reports the same baseline as before.
--- The fingerprint is what tells the two apart without a subprocess (perf P0-4).
---
--- Either side being unknown answers `true`: a redundant re-read costs a few
--- tens of milliseconds, a stale sign is a bug.
---@param st vcssign.AttachState
---@return boolean
local function baseline_moved(st)
  local stamp = stamp_of(st)
  return stamp == nil or st.base_stamp == nil or stamp ~= st.base_stamp
end

--- Read `HEAD` into `st.head_text` — the staged layer's baseline — then call
--- `done()`.
---
--- No `HEAD` yet (a repository born in this session, with a staged file) is
--- not a failure: the staged layer's baseline is the empty file, exactly like
--- an untracked file's, and every line reads as staged-added.
---@param st vcssign.AttachState
---@param done fun()
---@param staged boolean?  what the status view said; nil when this refresh has none
--- Read a baseline through the repository's batch reader when it has one (08
--- P0-2), or through the adapter's per-file command otherwise.
---
--- Everything that reads a baseline goes through here so that the two paths stay
--- interchangeable: they answer the same text (CRLF-free), and only the process
--- count differs.
---@param st vcssign.AttachState
---@param rev string
---@param cb fun(err: string?, text: string?)
local function show_text(st, rev, cb)
  local repo = st.repo
  if repo then
    return repo:read_blob(rev, st.rel, cb)
  end
  st.system.show(st.root, rev, st.rel, cb)
end

local function load_head(st, done, staged)
  -- `staged == false` is the status view saying the index matches `HEAD`, so the
  -- second layer has nothing to show and reading it would be pure cost (perf P0-1).
  if staged == false or not wants_staged(st) then
    st.head_text = nil
    return done()
  end
  show_text(st, 'HEAD', function(err, text)
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

--- The baseline read of a file known to be under version control.
---
--- `show(rev)` falls back once to `'HEAD'` before giving up; a failure is "no
--- signs" plus a debug line, never a warning (the stderr contract allows one
--- line, and the runtime spec owns it).
---@param st vcssign.AttachState
---@param done fun()
---@param staged boolean?  what the status view said, nil when unknown
local function load_base_show(st, done, staged)
  st.tracked, st.untracked, st.ignored = true, false, false
  ---@param rev string
  ---@param retry boolean
  local function show_with(rev, retry)
    show_text(st, rev, function(err, text)
      if M._bufs[st.bufnr] ~= st then
        return
      end
      if not err then
        st.base_text = text
        return load_head(st, done, staged)
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
end

--- Read both baselines through the adapter's per-file questions, then call
--- `done()`.
---
--- This is the path the status view replaced (perf P0-1), kept because it is the
--- only one a VCS without the primitive — or a failed query — has.
---
--- It cannot tell "ignored" from "untracked": `is_tracked` answers "no" for both
--- (`git ls-files --error-unmatch` does not consult the ignore rules).  So when
--- this path runs, an ignored file falls back to the untracked signs of D42
--- instead of the nothing D49 promises.  A second process (`git check-ignore`)
--- for a path that only runs once the status view has already failed is not
--- worth it.
---
--- Failure chain: an error from `is_tracked` is "no signs" (and no warning —
--- the stderr contract allows exactly one line, from the runtime spec);
--- `show(rev)` falls back once to `'HEAD'` before giving up.
---@param st vcssign.AttachState
---@param done fun()
---@param staged boolean?  what the status view said, nil when unknown
local function load_base_probe(st, done, staged)
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
      st.tracked, st.untracked, st.ignored = false, true, false
      -- An untracked file's baseline is the empty file, so every line is added
      -- (rendered as `untracked`, one sign per line).
      st.base_text = config.get().attach_to_untracked and '' or nil
      return done()
    end
    load_base_show(st, done, staged)
  end)
end

--- The status entry for `path`, honouring directory records.
---
--- An adapter may report a directory instead of every file below it; a buffer
--- inside one inherits the record's flags.  Production git status no longer
--- asks for ignored paths (D50), so for git this is the exact-key path with an
--- empty scan; svn still reports unversioned directories this way.
---@param entries table<string, vcssign.FileStatus>
---@param path string
---@return vcssign.FileStatus?
local function status_entry(entries, path)
  local entry = entries[path]
  if entry then
    return entry
  end
  for key, value in pairs(entries) do
    if value.dir and path:sub(1, #key + 1) == key .. '/' then
      return { tracked = false, staged = false, worktree = false, ignored = value.ignored }
    end
  end
  return nil
end

--- Both baselines from the repository's status view (perf P0-1), then `done()`.
---
--- The saving is not just "one query instead of three per buffer": a path the
--- view does not mention is in sync with its index/BASE, and for such a file
--- the baseline text *is* the buffer's own text — so a clean file costs no
--- subprocess at all.
---
--- Reading the buffer rather than the worktree on disk is deliberate, and it is
--- what keeps a stale answer harmless: the disk may have been edited after this
--- buffer read it (a missed fs event), and its *current* bytes would turn that
--- edit into phantom signs.  The buffer's text is what `show` would have
--- answered before anything moved, so a wrong "clean" degrades to "no signs" —
--- the pre-M7 answer — instead of inventing hunks.
---
--- A modified buffer is the case the shortcut cannot serve: its text is not the
--- baseline any more, so the real baseline is read.
---@param st vcssign.AttachState
---@param entries table<string, vcssign.FileStatus>
---@param trusted boolean  the view may be believed about staging (see `Repo:status`)
---@param done fun()
local function load_base_status(st, entries, trusted, done)
  local entry = status_entry(entries, st.path)
  if entry and entry.ignored then
    -- An ignored path is not "untracked with a twist": the repository was told
    -- to leave it alone, so vcssign claims nothing about it — no baseline, no
    -- signs, whatever `attach_to_untracked` says (D49).  `tracked` is false
    -- because the path really is outside the index; `untracked` is false
    -- because that flag is what draws the whole-file layer.  D50: production
    -- git/svn status no longer requests ignored paths, so they normally reach
    -- the absent (clean) branch below with the same visible result, no signs;
    -- this branch stays for adapters that still report them.
    st.tracked, st.untracked, st.ignored = false, false, true
    st.base_text = nil
    return done()
  end
  if entry and entry.added then
    -- `svn add` before the first commit: the path has no BASE and no HEAD node,
    -- so both `show` questions fail and the file would lose every sign —
    -- including the untracked layer it had a moment ago.  The empty baseline
    -- says exactly what the VCS knows: every line is an addition (D52).
    st.tracked, st.untracked, st.ignored = true, false, false
    st.added = true
    st.base_text = ''
    -- There is no HEAD node either, and no staging layer (svn); asking for
    -- one would only add a failed subprocess.
    return load_head(st, done, false)
  end
  if entry and not entry.tracked then
    st.tracked, st.untracked, st.ignored = false, true, false
    st.base_text = config.get().attach_to_untracked and '' or nil
    return done()
  end
  -- Written out: `entry and entry.staged or nil` can never answer nil.
  local staged, clean
  if entry == nil then
    -- Absent means "in sync with the index/BASE" — which also means the index
    -- has nothing staged, so the second layer has nothing to say (`nil` here
    -- would ask for `HEAD` and cost a subprocess for a clean file).
    clean = true
    if trusted then
      staged = false
    end
  else
    -- Only a view confirmed against the baseline key is believed about the
    -- second layer; `nil` means "read HEAD", which cannot be wrong.
    if trusted then
      staged = entry.staged == true
    end
    clean = entry.worktree == false
  end
  -- `clean` describes the worktree against the index/BASE; it says nothing
  -- about `rev`.  Under `rev = 'HEAD'` the buffer is a HEAD baseline only when
  -- the index itself is at HEAD (`staged == false`), and svn must read HEAD
  -- instead: its BASE is a checkout revision, not the server's HEAD.  An
  -- untrusted view may be from before the save that caused this read, so it
  -- cannot rule on either question (D53).
  local head_at_index = st.rev == 'HEAD'
    and st.system.capabilities.staged_signs == true
    and staged == false
  local from_buffer = trusted
    and clean
    and (st.rev == 'index' or head_at_index)
    and api.nvim_buf_is_loaded(st.bufnr)
    and not vim.bo[st.bufnr].modified
  if from_buffer then
    st.tracked, st.untracked, st.ignored = true, false, false
    st.base_text = diff.join(api.nvim_buf_get_lines(st.bufnr, 0, -1, false))
    return load_head(st, done, staged)
  end
  -- Tracked (or unknown-but-present) and not in sync: the baseline is read, but
  -- `is_tracked` is not asked again — the view already answered it.
  return load_base_show(st, done, staged)
end

--- Read the baseline text into `st`, then call `done()`.
---@param st vcssign.AttachState
---@param done fun()
local function load_base(st, done)
  -- Both baselines are re-read together (they have to describe the same
  -- moment), so a refresh cannot leave an older `head_text` behind: every
  -- branch below either sets it or leaves it nil.
  st.head_text = nil
  st.added = false
  -- Recorded *before* the read, not after: if the index moves while `show` is
  -- in flight, the stamp has to stay the older one so the next trigger re-reads
  -- instead of trusting text from a moment it never saw.
  st.base_stamp = stamp_of(st)
  local repo = st.repo
  if not repo then
    return load_base_probe(st, done, nil)
  end
  -- The status view is a repository-wide answer, so it is asked once and a
  -- failed query is not cached: this falls back to the per-file questions
  -- rather than dropping the signs.
  repo:status(function(serr, entries, trusted)
    if M._bufs[st.bufnr] ~= st then
      return
    end
    if serr or not entries then
      log.debug('buffer %d: no status view for %s: %s', st.bufnr, st.rel, serr or 'unknown')
      return load_base_probe(st, done, nil)
    end
    load_base_status(st, entries, trusted, done)
  end)
end

--- The config half of the render fingerprint.
---
--- `config.setup` replaces the whole table (`M.options = M.merge(...)`), so the
--- identity of the three tables the render reads covers a re-`setup()`; the
--- three flags are also compared by value, because the action layer flips
--- `word_diff` *in place* (`actions.toggle_word_diff`) and identity would not
--- see that.  A render-relevant option mutated in place inside `signs`/`diff`
--- is not detected — nothing in the plugin does that.
---@param conf vcssign.Config
---@return string
local function render_conf_key(conf)
  return table.concat({
    tostring(conf.signcolumn),
    tostring(conf.word_diff),
    tostring(conf.deleted_preview),
    tostring(conf.signs),
    tostring(conf.signs_staged),
    tostring(conf.diff),
  }, '|')
end

--- The only place the pipeline touches the buffer's contents.
---
--- `force` bypasses the short-circuit below.  The explicit entry points
--- (`:Vcssign refresh`, `toggle`, an action that just changed the index) pass
--- it: they must answer "the signs are current" even when this module cannot
--- see a difference from the last render.
---@param st vcssign.AttachState
---@param force boolean?  redraw even when the last render's inputs still hold
function M._render(st, force)
  local conf_key = render_conf_key(config.get())
  local tick = api.nvim_buf_get_changedtick(st.bufnr)
  local key = st.render_key
  if
    not force
    and key
    and key.tick == tick
    and key.base == st.base_text
    and key.head == st.head_text
    and key.shown == st.shown
    and key.conf == conf_key
  then
    -- Nothing this render reads has moved: no `nvim_buf_get_lines`, no diff,
    -- no extmark churn.  This is what makes a `FocusGained` sweep and a sweep
    -- after an fs event cost nothing (perf P0-4).  `changedtick` is the buffer
    -- half and it is bumped by every change, including `:e!`.
    return
  end
  local buf_lines = api.nvim_buf_get_lines(st.bufnr, 0, -1, false)
  st.buf_text = diff.join(buf_lines)
  -- Recorded before the branches below, every one of which leaves the buffer
  -- text, the two baselines and the switch in the state a later trigger skips
  -- on: only a successful render may claim to be current.
  st.render_key = {
    tick = tick,
    base = st.base_text,
    head = st.head_text,
    shown = st.shown,
    conf = conf_key,
  }
  st.hunks, st.hunks_staged = {}, {}
  if st.base_text == nil then
    clear_layers(st.bufnr)
    return
  end
  -- The signs and both previews read the same baseline: normalise it once and
  -- split it once (perf P2-3: `diff.normalize` used to run twice per render).
  local base_text = diff.normalize(st.base_text)
  local base_lines = diff.split(base_text)
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
    st.hunks = diff.run(base_text, st.buf_text)
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

--- Define every highlight group the plugin uses.
---
--- Four modules own groups, so the entry point lives here rather than in
--- `signs.lua`.  It runs on the first attach of a buffer (nothing may be drawn
--- with an undefined group) and again on `ColorScheme`: `define_highlights`
--- resolves the sign layer's candidate chain against the theme when it runs, so
--- a colorscheme loaded or switched later would leave a stale choice behind.
--- Every group is set with `default = true` and a re-run only fills groups that
--- are still default definitions, so a user's own override wins.
function M.define_highlights()
  signs.define_highlights()
  worddiff.define_highlights()
  preview.define_highlights()
  blame.define_highlights()
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
    if prev.path == path and not prev.abandoned then
      return prev
    end
    -- Either `:saveas` / `:e` renamed the buffer onto another file, or the
    -- repository we were attached to went away (`abandoned`).  A buffer that
    -- was *never* in a repository also has `attached == false`, but it is not
    -- abandoned: it keeps answering with the cached state, or every `BufEnter`
    -- would run detection again.
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
    abandoned = false,
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
    if M._bufs[bufnr] ~= st then
      return
    end
    -- Two very different triggers share this debounce: a buffer edit, which
    -- cannot have touched the baseline, and the repository saying "something
    -- moved on disk" (an fs event, or the probe behind `FocusGained`).  Only
    -- the second may need a new baseline, and only when the adapter's
    -- fingerprint moved — the render short-circuit covers the rest (perf P0-4).
    if baseline_moved(st) then
      M.refresh(bufnr)
    else
      M._render(st)
    end
  end)

  -- Stored *before* the asynchronous chain: `manager.attach` may answer
  -- synchronously, and the callback below must find this state.
  M._bufs[bufnr] = st

  M.define_highlights()

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
      repo:on_update(function(_, changed)
        -- `changed` is the channel the repository announces what the
        -- filesystem said moved (perf P0-3): a path set when the events named
        -- files, `nil` when something moved that names no file (the index /
        -- wc.db — every baseline may be stale), and empty when the probe found
        -- nothing moved at all (a `FocusGained` sweep, an explicit refresh).
        -- That last case is why this is not an unconditional `mark_dirty`.
        -- `st.path` and the recorded keys are both `base.normalize`d through
        -- the same root, so they compare directly: `:p` resolves the on-disk
        -- casing even when the buffer was opened with a lowercase drive letter
        -- (checked on Windows), so no `path_key` folding is needed here.
        if not changed or changed[st.path] then
          M.mark_dirty(bufnr)
        end
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
---
--- This is deliberately the *cheap* answer: the callback decides whether a
--- baseline re-read is needed at all (`baseline_moved`), so an edit made with
--- the index untouched costs no subprocess (perf P0-4).
---@param bufnr integer
function M.mark_dirty(bufnr)
  local st = M._bufs[bufnr]
  if not st or not st.enabled or not st.attached or not st.shown then
    return
  end
  st.refresh()
end

--- Rebuild a state that has answered "no repository", so the pipeline can try
--- again.
---
--- `M.attach` hands such a state back on purpose: re-probing there would run
--- detection for every `BufEnter` of every file that lives outside a working
--- copy.  An explicit request is different — `:Vcssign refresh` and `toggle`
--- are the user saying "look again", and that is how a repository created
--- after the buffer was opened is picked up without a `:e!`.
---@param bufnr integer
---@return vcssign.AttachState? st  the old state, or a fresh one
local function revive(bufnr)
  local st = M._bufs[bufnr]
  if not st or st.attached or not st.ready then
    return st
  end
  M.detach(bufnr)
  return M.attach(bufnr)
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
  local prev = M._bufs[bufnr]
  local st = revive(bufnr) or M.attach(bufnr)
  if not st then
    return nil
  end
  if st ~= prev then
    -- No state at all, or one that had answered "no repository": its switch
    -- was effectively off, so this press turns the signs *on* instead of
    -- flipping a state that was just built straight back off.
    return st.shown
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
  local st = revive(bufnr)
  if not st then
    if cb then
      cb('not attached')
    end
    return
  end
  if not st.attached then
    -- Revived, or still loading: wait for the pipeline's own answer and only
    -- then read the baseline, so `cb(nil)` keeps meaning "the signs are
    -- current now".  A state that answered "no repository" calls back with
    -- the error instead of looping.
    return M.ready(bufnr, function(err, ready)
      if not ready then
        return cb and cb(err or 'not attached')
      end
      M.refresh(bufnr, cb)
    end)
  end
  load_base(st, function()
    if M._bufs[bufnr] ~= st or not st.attached then
      if cb then
        cb('not attached')
      end
      return
    end
    -- Forced: this is the explicit "read it again and draw it" contract.
    M._render(st, true)
    if cb then
      cb(nil)
    end
  end)
end

--- `BufWritePost`: the file landed on disk.
---
--- Tell the status view before anything re-reads the baseline (D51): a save
--- does not move `wc.db` / the index, so no fs event retires the view (D38).
--- Without the note the view still says clean, `from_buffer` takes the saved
--- buffer as its own baseline, and every hunk disappears.  When the metadata
--- did not move there is also nothing to re-read: draw from the baseline the
--- existing signs already describe, for free.
---@param bufnr integer
function M.note_written(bufnr)
  local st = M._bufs[bufnr]
  if not st then
    return M.refresh(bufnr)
  end
  local repo = st.repo
  local mode
  if repo and st.path then
    -- A save moves nothing `Repo:_stamp()` watches, so the view has to be told
    -- about the save *before* we ask `baseline_moved`: that answers "is the
    -- store still the one this buffer was read at?", not "is the view still
    -- the one this buffer was read from?" - a foreign reader may have
    -- repopulated the view at a newer stamp while this buffer's `base_stamp`
    -- stayed older, and skipping the note there lets `from_buffer` baseline
    -- the saved text (D53).  `tracked` stays `nil` during attach; the view is
    -- then retired rather than guessed at (an absent entry cannot tell a clean
    -- file from an ignored one).
    mode = repo:note_save(st.path, st.tracked)
  end
  if mode == 'deferred' then
    -- The in-flight query answers for the pre-save moment.  Wait for it, then
    -- ask again: joining it would hand this refresh the stale view.
    return repo:after_status(function()
      if M._bufs[bufnr] == st and st.attached then
        M.refresh(bufnr)
      end
    end)
  end
  if baseline_moved(st) then
    -- `git add` / `svn commit` moved the baseline; only a re-read is correct.
    return M.refresh(bufnr)
  end
  if not st.ready or not st.attached or st.base_text == nil then
    return M.refresh(bufnr)
  end
  M._render(st)
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

--- Bring every attached buffer up to date.  This is the `FocusGained`
--- fallback: the index may have moved while another program held the focus and
--- Windows fs events are not guaranteed to arrive.
---
--- The sweep runs on every focus gain, so it must be free when nothing moved:
--- a buffer whose baseline fingerprint is unchanged is only re-rendered, which
--- the render short-circuit turns into a `changedtick` comparison (perf P0-4).
function M.refresh_all()
  for _, bufnr in ipairs(M.buffers()) do
    local st = M._bufs[bufnr]
    -- A user adapter's `baseline_stamp` runs inside this loop and could detach,
    -- so the state is looked up per buffer and may legitimately be gone.
    if st and baseline_moved(st) then
      M.refresh(bufnr)
    elseif st then
      M._render(st)
    end
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
    keymap.detach(st.bufnr)
    blame.detach(st.bufnr)
    st.refresh_cancel()
    unobserve(st)
    settle(st, 'the signs were dropped')
  end
  M._bufs = {}
end

return M
