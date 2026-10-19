--- The action layer: the only place that turns user intent into VCS commands.
---
--- Everything above it (the `:Vcssign` commands, the buffer-local default
--- keymaps in `vcssign.keymap`) asks for a *file* and an *intent*; everything
--- below it (the adapters) runs one command.  So this file is where the interesting policy lives: which file
--- an action applies to, which capability it needs, which command variant the
--- configured baseline implies (`rev == 'index'` means the staging baseline),
--- whether a commit has anything staged to record, and what the user is told
--- when the answer is no.
---
--- Every action takes the same target — a path, or nothing at all (then: the
--- file of the current buffer).  Status entries are gone with the sidebar (M5)
--- and the repository no longer caches a file list (D38), so a target is always
--- resolved from the path itself.
--- See impl/archive/actions/ §2.
local attach = require('vcssign.attach')
local blame = require('vcssign.blame')
local config = require('vcssign.config')
local diff = require('vcssign.diff')
local hunk = require('vcssign.hunk')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local preview = require('vcssign.preview')
local revdiff = require('vcssign.revdiff')
local signs = require('vcssign.signs')
local base = require('vcssign.vcs.base')

local uv = vim.uv

local M = {}

---@param fmt string
---@param ... any
local function info(fmt, ...)
  log.notify(select('#', ...) == 0 and fmt or string.format(fmt, ...))
end

--- A system-scoped refusal (`svn: no staging area`) reads as the *system*
--- talking, and both the hunk keys and this layer phrase it the same way —
--- so it gets no `vcssign:` prefix.
---@param fmt string
---@param ... any
local function refuse(fmt, ...)
  vim.notify(string.format(fmt, ...), vim.log.levels.INFO)
end

---@param fmt string
---@param ... any
local function fail(fmt, ...)
  log.notify_error(select('#', ...) == 0 and fmt or string.format(fmt, ...))
end

-- ▏ targeting ─────────────────────────────────────────────────────────────────

---@class vcssign.Target
---@field repo vcssign.Repo
---@field path string      absolute
---@field rel_path string  relative to the repository root

--- Default target: the current buffer's file, else the cwd (a `:Vcssign
--- refresh` from an empty scratch buffer).
---@return string
local function default_target()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' then
    return name
  end
  return uv.cwd() or '.'
end

--- The repository that owns a path: the deepest attached one containing it.
---@param path string
---@return vcssign.Repo?
local function repo_of(path)
  return manager.get_by_path(path)
end

--- Resolve a target into the repository that owns it plus the file's path.
---@param target string|nil
---@return vcssign.Target?, string? err
local function resolve(target)
  local path = base.normalize(target or default_target())
  local repo = repo_of(path)
  if not repo then
    return nil, string.format('no repository for %s', path)
  end
  local rel = base.relpath(path, repo.root)
  if rel == nil then
    return nil, string.format('%s is outside %s', path, repo.root)
  end
  return {
    repo = repo,
    path = path,
    rel_path = rel,
  }
end

-- ▏ diff ────────────────────────────────────────────────────────────────────

--- The window and the scratch buffer the diff is shown in live in
--- `vcssign.revdiff` (Step 11 moved them there: `diffthis <rev>` shows its
--- own text in the same window).  What is left here is the policy: which
--- baseline the configured `rev` means, and when "no diff" is an answer.

--- Which baseline to diff against.
---
--- The repository no longer caches status (D38), so this comes straight from
--- the configured baseline (D42): `rev == 'index'` is the staging baseline and
--- asks the adapter for the staged view.  Anything else is a revision, which
--- the adapter reads through the (git-only) `HEAD`-style diff.  svn ignores the
--- flag either way and always diffs the working copy.
---@return boolean
local function cached_diff()
  return config.get().rev == 'index'
end

function M.diff(target, opts)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  -- `diff` no longer has a capability key of its own (D38), but reading the
  -- baseline is exactly what a diff needs, and keeping the check keeps the
  -- ":Vcssign diff" answer in doc/vcssign.txt §3 honest.
  if not t.repo.system.capabilities.show_rev then
    return refuse('%s: diff is not supported', t.repo.system.name)
  end
  ---@param cached boolean
  local function show(cached)
    t.repo.system.diff(t.repo.root, t.rel_path, { cached = cached }, function(diff_err, text)
      if diff_err then
        return fail(diff_err)
      end
      if text == nil or vim.trim(text) == '' then
        -- "No diff" is an answer, not a failure: svn prints nothing for a
        -- property-only change, and git prints nothing for an unmodified file.
        return info('%s: no changes to show', t.rel_path)
      end
      revdiff.show(t, text)
    end)
  end

  local cached = opts and opts.cached
  if cached == nil then
    cached = cached_diff()
  end
  show(cached)
end

-- ▏ stage / unstage ──────────────────────────────────────────────────────────

---@param target string|nil
---@param action "stage"|"unstage"
local function stage_like(target, action)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  local repo = t.repo
  -- One capability covers both directions: staging *is* the index, and taking
  -- a change back out of it needs the same index (svn has neither).
  if not repo.system.capabilities.stage then
    return refuse('%s: no staging area', repo.system.name)
  end
  repo.system[action](repo.root, { t.rel_path }, function(cmd_err)
    if cmd_err then
      return fail(cmd_err)
    end
    info('%s %s', action == 'stage' and 'staged' or 'unstaged', t.rel_path)
    -- Straight away, not debounced: the status has almost certainly just
    -- changed.
    repo:refresh_now()
  end)
end

--- Move a file's changes into the index (git).
---@param target string|nil
function M.stage(target)
  stage_like(target, 'stage')
end

--- Take a file's changes back out of the index (git).
---@param target string|nil
function M.unstage(target)
  stage_like(target, 'unstage')
end

-- ▏ hunk actions ─────────────────────────────────────────────────────────────
--
-- Everything here is "one hunk of the open file": the hunk comes from the
-- buffer's cursor, the text from the buffer, and the command from the adapter.
-- The patch is built by `vcssign.hunk.build_patch` (zero context, the shape
-- `git apply --unidiff-zero -` wants, D41), and what differs between staging,
-- unstaging and discarding is exactly *which baseline* it is built against.

---@class vcssign.HunkCtx
---@field t vcssign.Target
---@field bufnr integer
---@field st vcssign.AttachState
---@field hunk vcssign.Hunk
---@field layer "worktree"|"staged"

--- The loaded buffer showing `path`, when there is one.
---@param path string
---@return integer?
local function buffer_showing(path)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= '' and base.normalize(name) == path then
        return bufnr
      end
    end
  end
end

--- The line a hunk action applies to: the cursor of the window showing the
--- buffer.  A file that is not on screen has no cursor, and the command line is
--- read by scripts, so line 1 is the answer there.
---@param bufnr integer
---@return integer
local function cursor_line(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return 1
  end
  return vim.api.nvim_win_get_cursor(win)[1]
end

--- The hunk a line belongs to.
---
--- A line is inside a hunk when it is one of its *added* lines; a hunk that only
--- removes lines has none, so it is hit on exactly the line its sign hangs on
--- (`vcssign.signs.sign_line`) — the line `]c` jumps to.
---@param hunks vcssign.Hunk[]
---@param lnum integer 1-based
---@return vcssign.Hunk?
local function hunk_at(hunks, lnum)
  for _, h in ipairs(hunks) do
    if h.added.count > 0 then
      if lnum >= h.added.start and lnum <= h.added.start + h.added.count - 1 then
        return h
      end
    elseif signs.sign_line(h) == lnum then
      return h
    end
  end
end

--- The patch that turns `base_text` into `buf_text` for one hunk.
---
--- The hunk model carries no "this side does not end in a newline", so it is
--- reconstructed here — and only for a hunk that actually reaches the end of
--- the side it describes, which is the shape git's parser expects.
---@param h vcssign.Hunk
---@param base_text string
---@param buf_text string
---@param rel string
---@param bufnr integer
---@return string
local function patch_of(h, base_text, buf_text, rel, bufnr)
  local base_lines, buf_lines = diff.split(base_text), diff.split(buf_text)
  local base_eof = h.removed.count > 0 and h.removed.start + h.removed.count - 1 == #base_lines
  local buf_eof = h.added.count > 0 and h.added.start + h.added.count - 1 == #buf_lines
  return hunk.build_patch(h, base_lines, buf_lines, rel, {
    base_no_nl_at_eof = base_eof and base_text ~= '' and base_text:sub(-1) ~= '\n',
    buf_no_nl_at_eof = buf_eof and vim.bo[bufnr].endofline == false,
  })
end

--- Resolve the buffer, the repository and the hunk a hunk action works on.
---
--- Asynchronous in exactly one direction: a buffer whose first baseline is still
--- in flight waits through `attach.ready`.  A cursor that is not on a hunk is an
--- answer ("nothing to do"), not a failure.
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer, layer?: "worktree"|"staged" }
---@param cb fun(ctx: vcssign.HunkCtx?, err: string?)
local function hunk_ctx(target, opts, cb)
  opts = opts or {}
  local path = base.normalize(target or default_target())
  local bufnr
  if opts.bufnr and vim.api.nvim_buf_is_valid(opts.bufnr) then
    bufnr = opts.bufnr
  else
    bufnr = buffer_showing(path)
  end
  -- Hunk actions need the *buffer*: the hunk is picked with the cursor and the
  -- text comes from the buffer, which may hold changes the file on disk does
  -- not have.  Using whatever buffer happens to be current instead would be a
  -- way to patch a file the user did not point at.
  if not bufnr then
    return cb(nil, string.format('%s is not open in a buffer', path))
  end
  attach.ready(bufnr, function(rerr, st)
    if not st then
      return cb(nil, rerr)
    end
    local t, terr = resolve(vim.api.nvim_buf_get_name(bufnr))
    if not t then
      return cb(nil, terr)
    end
    if st.base_text == nil then
      return cb(nil, string.format('%s has no baseline to differ from', t.rel_path))
    end
    local layer = opts.layer or 'worktree'
    local hunks = layer == 'staged' and st.hunks_staged or st.hunks
    local lnum = opts.lnum or cursor_line(bufnr)
    local h = hunk_at(hunks, lnum)
    if not h then
      return cb(nil, string.format('no change on line %d of %s', lnum, t.rel_path))
    end
    cb({ t = t, bufnr = bufnr, st = st, hunk = h, layer = layer })
  end)
end

--- Put a buffer back in sync with the file a patch just rewrote.
---
--- `:edit!` is the honest way: the caller refused to act on a modified buffer,
--- so the file is the source of truth, and re-reading it also re-runs the attach
--- pipeline (`on_detach`, then `BufReadPost`).  `nvim_buf_call` makes the
--- commands apply to a buffer that is not on screen, too.
---@param bufnr integer
---@param cb fun()
local function reload(bufnr, cb)
  if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr) then
    local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd('silent! edit!')
    end)
    if not ok then
      return cb()
    end
  end
  -- `:edit!` detaches and `BufReadPost` attaches again; waiting for the new
  -- baseline also covers a session without the autocmds, because `attach.ready`
  -- attaches on demand.
  attach.ready(bufnr, function()
    cb()
  end)
end

--- Stage one hunk (git): put just this region's change into the index.
---
--- The patch is `index` -> buffer (the worktree layer's baseline) applied to the
--- index.  An untracked file has no index blob to patch against, so its single
--- "hunk" (the whole file, §3.2) stages as a whole.
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer }
function M.stage_hunk(target, opts)
  hunk_ctx(target, opts, function(ctx, err)
    if not ctx then
      return fail(err)
    end
    local t, st = ctx.t, ctx.st
    if not t.repo.system.capabilities.stage then
      return refuse('%s: no staging area', t.repo.system.name)
    end
    if st.untracked then
      return M.stage(t.path)
    end
    local patch = patch_of(ctx.hunk, st.base_text, st.buf_text, t.rel_path, ctx.bufnr)
    t.repo.system.apply_patch(t.repo.root, patch, { cached = true }, function(aerr)
      if aerr then
        return fail(aerr)
      end
      info('staged %s (line %d)', t.rel_path, signs.sign_line(ctx.hunk))
      -- Refresh this buffer now, not 200ms from now: the *next* hunk action reads
      -- the layers on screen, so `hs` followed by `hu` must see the new split.
      -- The repository's own probe is left to the debounce — the index write
      -- already produced a filesystem event, and staging changed that store's
      -- fingerprint, so the status view (and the blob reader, perf P0-1/P0-2) are
      -- rebuilt on their own.  Asking for both paths here meant two refreshes
      -- for one action (perf §7-5, §2.9).
      attach.refresh(ctx.bufnr)
    end)
  end)
end

--- Take one hunk back out of the index (git).
---
--- The patch is `HEAD` -> buffer for the *staged* hunk, applied reversed to the
--- index: the index returns to what `HEAD` holds there and the buffer keeps the
--- change as an unstaged one.  (gitsigns' `undo_stage_hunk` replays a stack of
--- the patches staged earlier in the session instead; ours acts on the hunk the
--- signs describe — signs §9.)
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer }
function M.unstage_hunk(target, opts)
  hunk_ctx(target, vim.tbl_extend('force', opts or {}, { layer = 'staged' }), function(ctx, err)
    if not ctx then
      return fail(err)
    end
    local t, st = ctx.t, ctx.st
    if not t.repo.system.capabilities.stage then
      return refuse('%s: no staging area', t.repo.system.name)
    end
    if st.head_text == nil then
      return refuse('%s: there is no staged layer to take a hunk from', t.rel_path)
    end
    local patch = patch_of(ctx.hunk, st.head_text, st.buf_text, t.rel_path, ctx.bufnr)
    t.repo.system.apply_patch(t.repo.root, patch, { cached = true, reverse = true }, function(aerr)
      if aerr then
        return fail(aerr)
      end
      info('unstaged %s (line %d)', t.rel_path, signs.sign_line(ctx.hunk))
      -- Same as `stage_hunk`: this buffer now, the repository's probe debounced.
      attach.refresh(ctx.bufnr)
    end)
  end)
end

--- The keymap's spelling (`hu`, §4).
M.undo_stage_hunk = M.unstage_hunk

--- Throw one hunk away: the file goes back to whatever the baseline holds
--- there.
---
--- This is the only action that rewrites the *file*, so a modified buffer is
--- refused (D45): the patch is built from the buffer's text but applied to the
--- file, and the two have to describe the same bytes.
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer }
function M.reset_hunk(target, opts)
  hunk_ctx(target, opts, function(ctx, err)
    if not ctx then
      return fail(err)
    end
    local t, st = ctx.t, ctx.st
    if not t.repo.system.capabilities.revert_hunk then
      return refuse('%s: discarding hunks is not supported', t.repo.system.name)
    end
    if st.untracked then
      return info('%s is not tracked yet: nothing to discard', t.rel_path)
    end
    if vim.bo[ctx.bufnr].modified then
      return refuse('%s has unsaved changes: save or undo them first', t.rel_path)
    end
    local patch = patch_of(ctx.hunk, st.base_text, st.buf_text, t.rel_path, ctx.bufnr)
    t.repo.system.apply_patch(t.repo.root, patch, { reverse = true }, function(aerr)
      if aerr then
        return fail(aerr)
      end
      info('discarded %s (line %d)', t.rel_path, signs.sign_line(ctx.hunk))
      reload(ctx.bufnr, function()
        t.repo:refresh_now()
      end)
    end)
  end)
end

--- Stage a whole file (git).  The keymap vocabulary's name for `M.stage` (`hs`
--- stages one hunk, `hS` the file, §4).
---@param target string|nil
function M.stage_buffer(target)
  return M.stage(target)
end

--- Throw away every change in one file.
---@param target string|nil
---@param opts? { bufnr?: integer }
function M.reset_buffer(target, opts)
  opts = opts or {}
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  if not t.repo.system.capabilities.revert_hunk then
    return refuse('%s: discarding changes is not supported', t.repo.system.name)
  end
  local bufnr = opts.bufnr or buffer_showing(t.path)
  if bufnr and vim.bo[bufnr].modified then
    return refuse('%s has unsaved changes: save or undo them first', t.rel_path)
  end
  t.repo.system.revert(t.repo.root, t.rel_path, function(rerr)
    if rerr then
      return fail(rerr)
    end
    info('discarded changes in %s', t.rel_path)
    if bufnr then
      return reload(bufnr, function()
        t.repo:refresh_now()
      end)
    end
    t.repo:refresh_now()
  end)
end

-- ▏ preview ──────────────────────────────────────────────────────────────────────────

--- Show one hunk as a unified diff in a floating window, or close it when that
--- hunk is already on show (`hp`, §4).
---
--- Read-only: no patch is built, nothing is refreshed.  The preview describes
--- the hunk the signs already have, so it goes through `hunk_ctx` like every
--- other hunk action (the cursor decides which hunk, and a buffer that is still
--- loading its baseline is waited for instead of guessed at).
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer, layer?: 'worktree'|'staged' }
function M.preview_hunk(target, opts)
  hunk_ctx(target, opts, function(ctx, err)
    if not ctx then
      return fail(err)
    end
    local st = ctx.st
    -- The staged layer's hunks were diffed against `HEAD`, so that is the text
    -- to show them against; the worktree layer's against the baseline.
    local base_text = ctx.layer == 'staged' and st.head_text or st.base_text
    if base_text == nil then
      return fail('%s has no baseline to preview against', ctx.t.rel_path)
    end
    preview.toggle_hunk(
      ctx.bufnr,
      ctx.hunk,
      signs.sign_line(ctx.hunk),
      diff.split(diff.normalize(base_text)),
      diff.split(st.buf_text)
    )
  end)
end

--- Turn the inline word diff on or off, for every attached buffer (`tw`, §4).
---
--- The switch is one config key, not per buffer, so this re-renders all of them:
--- the alternative would be two buffers disagreeing about the setting.
---
--- `config.get()` is mutated in place: `config.setup` re-merges from the
--- defaults, so calling it here would throw away every other option the user
--- set.
function M.toggle_word_diff()
  local cfg = config.get()
  cfg.word_diff = not cfg.word_diff
  attach.refresh_all()
  info('word diff %s', cfg.word_diff and 'on' or 'off')
end

-- ▏ commit ───────────────────────────────────────────────────────────────────

--- Ask for a commit message, then hand it to `cb`.  Not called at all when the
--- user cancels or types nothing: a commit message nobody wrote is a commit
--- nobody wanted.
---@param cb fun(msg: string)
local function ask_message(cb)
  local mode = config.get().commit.message_input
  if mode ~= 'input' then
    log.warn('commit.message_input = %q is not implemented yet; using "input"', mode)
  end
  vim.ui.input({ prompt = 'Commit message: ' }, function(input)
    if input == nil then
      -- Cancelled (Esc / C-c).
      return
    end
    local msg = vim.trim(input)
    if msg == '' then
      return info('empty commit message: nothing was committed')
    end
    cb(msg)
  end)
end

--- Whether the index holds a change a commit would record.
---
--- The repository view already answers this for every path (perf P0-1): a staged
--- change is `staged` on its entry, and a path the view does not mention is in
--- sync with `HEAD`.  So the usual cost is zero — but the view is only believed
--- when it was taken from the store as it is now; if the store moved after the
--- query (`trusted` false) it may be describing an index somebody else has
--- already staged into, and then the two reads below answer directly.
--- (svn has no index: the view reports `staged = false` for everything, which is
--- the same answer the reads used to give.)
---@param t vcssign.Target
---@param cb fun(staged: boolean)
local function has_staged_change(t, cb)
  local root, rel = t.repo.root, t.rel_path
  t.repo:status(function(serr, entries, trusted)
    if not serr and trusted and entries then
      local entry = entries[base.normalize(vim.fs.joinpath(root, rel))]
      return cb(entry ~= nil and entry.staged == true)
    end
    t.repo.system.show(root, 'index', rel, function(index_err, index_text)
      if index_err then
        return cb(false)
      end
      t.repo.system.show(root, 'HEAD', rel, function(head_err, head_text)
        if head_err then
          return cb(true)
        end
        cb(index_text ~= head_text)
      end)
    end)
  end)
end

--- Commit one file.
---
--- git records what is in the *index*, so a file with nothing staged is refused
--- with a pointer at the key that fixes it (the plan deliberately rules out
--- "commit the worktree as well" — actions §2.2).  svn has no index: its working
--- copy is the thing being committed.
---@param target string|nil
---@param opts? { message?: string }  skips the prompt (used by the specs)
function M.commit(target, opts)
  opts = opts or {}
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  local repo = t.repo
  if not repo.system.capabilities.commit then
    return refuse('%s: commit is not supported', repo.system.name)
  end
  local stat = uv.fs_stat(t.path)
  if stat and stat.type ~= 'file' then
    -- svn lists directories (`svn status` reports the directory itself), and
    -- `svn commit -- <dir>` commits the whole subtree by default: refusing is
    -- friendlier than committing more than the row the user pointed at.
    return info('%s is not a file: commit its files one by one', t.rel_path)
  end

  local function commit(msg)
    repo.system.commit(repo.root, { t.rel_path }, msg, function(cmd_err, summary)
      if cmd_err then
        return fail(cmd_err)
      end
      info(
        'committed %s%s',
        t.rel_path,
        summary and summary ~= '' and (' (' .. summary .. ')') or ''
      )
      repo:refresh_now()
    end)
  end

  ---@param staged boolean
  local function ask_or_commit(staged)
    if not staged then
      if repo.system.capabilities.stage then
        -- git: the change is in the worktree, not in the index.
        return info('%s is not staged yet (press s)', t.rel_path)
      end
      -- svn: no staging area to point at, so let svn itself report that there
      -- is nothing to send.
    end
    if opts.message then
      commit(opts.message)
    else
      ask_message(commit)
    end
  end

  if repo.system.capabilities.stage then
    has_staged_change(t, ask_or_commit)
  else
    ask_or_commit(true)
  end
end

-- ▏ blame / rev diff ────────────────────────────────────────────────────────

--- Ask for a revision, the way `ask_message` asks for a commit message.
---@param prompt string
---@param cb fun(rev: string)
local function ask_rev(prompt, cb)
  vim.ui.input({ prompt = prompt }, function(input)
    if input == nil then
      -- Cancelled (Esc / C-c).
      return
    end
    local rev = vim.trim(input)
    if rev ~= '' then
      cb(rev)
    end
  end)
end

--- `diffthis`: the file against the configured baseline, or against `opts.rev`.
---
--- The baseline case *is* the plain `diff` action -- the same comparison, and
--- the one `system.diff` can print itself.  A named revision is built by
--- `vcssign.revdiff` from `show(root, rev, rel)` and the buffer's lines: no
--- adapter can diff an arbitrary revision for us, and the buffer's text (saved
--- or not) is what the user is looking at.
---@param target string|nil
---@param opts? { rev?: string }
function M.diffthis(target, opts)
  local rev = opts and opts.rev
  if rev == nil or rev == '' then
    return M.diff(target)
  end
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  if not t.repo.system.capabilities.show_rev then
    return refuse('%s: diff is not supported', t.repo.system.name)
  end
  local bufnr = buffer_showing(t.path)
  if not bufnr then
    return fail(string.format('%s is not open in a buffer', t.rel_path))
  end
  t.repo.system.show(t.repo.root, rev, t.rel_path, function(show_err, text)
    if show_err then
      return fail(show_err)
    end
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local body = revdiff.text(t.rel_path, text or '', buf_lines)
    if body == '' then
      return info('%s: no changes against %s', t.rel_path, rev)
    end
    revdiff.show(t, body)
  end)
end

--- `diffthis_rev`: ask which revision, then show it.
---@param target string|nil
---@param opts? { rev?: string }
function M.diffthis_rev(target, opts)
  local rev = opts and opts.rev
  if rev and rev ~= '' then
    return M.diffthis(target, { rev = rev })
  end
  ask_rev('Revision to compare with: ', function(input)
    M.diffthis(target, { rev = input })
  end)
end

--- `blame_line`: the blame of one line in a float (`vcssign.blame`).
---@param target string|nil
---@param opts? { bufnr?: integer, lnum?: integer }
function M.blame_line(target, opts)
  opts = opts or {}
  local bufnr = opts.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    local t, err = resolve(target)
    if not t then
      return fail(err)
    end
    bufnr = buffer_showing(t.path)
    if not bufnr then
      return fail(string.format('%s is not open in a buffer', t.rel_path))
    end
  end
  local lnum = opts.lnum or cursor_line(bufnr)
  blame.line(bufnr, lnum, function(err)
    if err then
      return fail(err)
    end
  end)
end

--- `toggle_current_line_blame`: the decoration takes the configured delay
--- anyway, so a buffer that already has the cursor on screen re-renders by
--- itself.
function M.toggle_current_line_blame()
  local cfg = config.get()
  cfg.current_line_blame = not cfg.current_line_blame
  blame.refresh_all()
  info('blame %s', cfg.current_line_blame and 'on' or 'off')
end

-- ▏ refresh ──────────────────────────────────────────────────────────────────

--- Refresh the repository of a file (or of the only attached one).
---
--- `refresh` is the one action whose argument is a *repository*, not a file, so
--- it works without a current file too — `:Vcssign refresh` from a scratch
--- buffer in a session with exactly one repository means that repository.
---@param target string|nil
function M.refresh(target)
  local t, err = resolve(target)
  if t then
    return t.repo:refresh_now()
  end
  local all = manager.all()
  if #all == 1 then
    return all[1]:refresh_now()
  end
  fail(err)
end

return M
