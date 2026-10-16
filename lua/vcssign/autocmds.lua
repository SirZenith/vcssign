--- Editor-wide lifecycle: which autocmd attaches a buffer to the signs
--- pipeline, which one refreshes it, which one cleans up.
---
--- Step 6 moved the per-buffer policy (baseline, debounce, on/off switch) into
--- `attach.lua`; what is left here is only the *trigger* layer.  That split is
--- what keeps `setup()` safe to run twice: this module owns nothing but the
--- augroup and the two manager hooks, so there is no state to leak.
--- The plan (04 §4) put a 100ms debounce around attach calls to absorb
--- `BufEnter` storms; `attach.attach` answers a second call for a buffer it
--- already holds with a table lookup instead, which does not delay the very
--- first attach after opening a file — the one the user is waiting for.
---
--- `setup()` also attaches the buffers that are already on screen.  A plugin
--- loaded on a `BufEnter` trigger (lazy.nvim, `:packadd`) starts *after* that
--- event fired for the file the user opened, and no further event is coming
--- for it: without the sweep the sign column would stay empty until the user
--- leaves and re-enters the buffer.
--- See impl/init/07-signs-in-signcolumn.md §6.
local attach = require('vcssign.attach')
local config = require('vcssign.config')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')

local M = {}

M.group_name = 'vcssign'

---@type fun()[]
M._unsubscribe = {}

---@param repo vcssign.Repo
local function fire_config_hook(name, repo)
  local hook = config.get()[name]
  if type(hook) ~= 'function' then
    return
  end
  -- A user hook that raises must not take the attach (or the editor) down.
  local ok, err = pcall(hook, repo)
  if not ok then
    log.error('%s hook failed: %s', name, tostring(err))
  end
end

--- Attach `bufnr` to the signs pipeline.
---
--- Every eligibility check (unnamed, non-file buftype, missing on disk, too
--- long) lives in `attach.attach`, which is idempotent for a buffer it already
--- holds and re-attaches after `on_detach` (`:e!`, `:saveas`).
---@param bufnr integer
function M.attach_buffer(bufnr)
  attach.attach(bufnr)
end

---@param bufnr integer
function M.detach_buffer(bufnr)
  attach.detach(bufnr)
end

---@param cwd string
function M.attach_cwd(cwd)
  -- One reusable reference: moving again rebinds it, and a new cwd outside any
  -- repository releases it (`attach` detaches the reference when detection
  -- comes up empty).
  manager.attach('cwd', cwd, function(err, repo)
    log.debug('cwd %s: %s', cwd, repo and repo.root or (err or 'no repository'))
  end)
end

--- Re-read the baseline of every attached buffer (the `FocusGained` sweep).
function M.refresh_buffers()
  attach.refresh_all()
end

--- Create the `vcssign` augroup, wire the lifecycle events, and attach the
--- buffers that are already on screen.
function M.setup()
  M.disable()
  local group = vim.api.nvim_create_augroup(M.group_name, { clear = true })
  ---@param event string|string[]
  ---@param callback function
  local function subscribe(event, callback, opts)
    vim.api.nvim_create_autocmd(
      event,
      vim.tbl_extend('force', { group = group, callback = callback }, opts or {})
    )
  end

  -- Files: attaching on both events covers `nvim file` (BufReadPost, before the
  -- window is fully set up) and jumping between buffers.  `attach_buffer` is
  -- idempotent, so the pair costs one table lookup on the common path.
  subscribe({ 'BufReadPost', 'BufEnter' }, function(args)
    M.attach_buffer(args.buf)
  end)

  -- A buffer that goes away releases its reference; otherwise the last
  -- reference to a repository could outlive its only buffer.  (`on_detach` in
  -- `attach.lua` is the other side of the same guarantee — either one alone
  -- can miss a path, so both are wired.)
  subscribe({ 'BufDelete', 'BufWipeout' }, function(args)
    M.detach_buffer(args.buf)
  end)

  -- No `WinEnter` hook here: vcssign never writes the window's `'signcolumn'`
  -- (07 §6.3).  `config.signcolumn` is a boolean that decides whether the sign
  -- text is drawn, and `signs.place` reads it on every render.
  -- The worktree and the index may disagree again the moment the file lands on
  -- disk.  `on_lines` already covers an edit, but `:w` can happen with no text
  -- change at all (a write after an external edit), so the event gets its own
  -- refresh.
  subscribe('BufWritePost', function(args)
    attach.refresh(args.buf)
  end)

  subscribe('DirChanged', function(args)
    -- For this event the details live in `v:event` (scope/cwd), not in the
    -- callback's arguments (`args.file` happens to hold the new directory as
    -- well).  `:lcd` / `:tcd` fire it too, and for those the global cwd is not
    -- the directory the event is about — attaching it would pin an unrelated
    -- repository.
    local event = vim.v.event or {}
    if event.scope and event.scope ~= 'global' then
      return
    end
    local cwd = event.cwd or args.file or vim.uv.cwd()
    if cwd and cwd ~= '' then
      M.attach_cwd(cwd)
    end
  end)

  -- A colorscheme loaded (or switched) after the first attach must re-resolve
  -- the sign groups' candidate chain: `signs.define_highlights` picks the
  -- theme's git-sign group when it runs, and it only fills groups that are
  -- still default definitions, so a user's own overrides survive the re-run.
  -- gitsigns re-runs its highlight setup on the same event (`highlight.lua`).
  subscribe('ColorScheme', function()
    attach.define_highlights()
  end)

  -- Focus is the reliable fallback on Windows, where a file changed by another
  -- program (`git checkout` in a terminal, an editor outside nvim) may produce
  -- no event we can see.  Both halves are needed: the repositories re-probe
  -- (and notice that they were deleted), the buffers re-read their baseline.
  -- `Repo` debounces its own refresh, so a burst of focuses stays cheap.
  subscribe('FocusGained', function()
    M.refresh_buffers()
    for _, repo in ipairs(manager.all()) do
      repo:refresh()
    end
  end)

  -- Nothing may outlive the session: forget the buffers and dispose of every
  -- repository with its watchers.  Releasing the handles is the part that must
  -- not be skipped.
  subscribe('VimLeavePre', function()
    attach.forget_all()
    manager.dispose_all()
  end)

  M._unsubscribe = {
    manager.on_repo_attached(function(repo)
      fire_config_hook('on_attach', repo)
    end),
    manager.on_repo_detached(function(repo)
      fire_config_hook('on_detach', repo)
    end),
  }

  -- Attach what is already on screen.  A plugin loaded on a `BufEnter`
  -- trigger (lazy.nvim, `:packadd`) starts *after* that event fired for the
  -- file the user opened, and no second event is coming for it.  gitsigns
  -- sweeps every loaded buffer here ("Attach to all open buffers",
  -- `gitsigns.lua`); the windows are the narrower version of that: what is
  -- visible is what has an empty sign column to fill, and a hidden buffer
  -- gets its own `BufEnter` when it is shown again.  `M.attach_buffer` holds
  -- every eligibility test and answers a buffer it already holds from its
  -- state table, so a sweep costs table lookups, not new `git`/`svn`
  -- detection.
  local seen = {}
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if not seen[bufnr] then
      seen[bufnr] = true
      M.attach_buffer(bufnr)
    end
  end
end

--- Remove every autocmd and hook this module installed.  Idempotent; `setup()`
--- calls it first, and the specs call it in their teardown so one case's
--- attach-on-BufEnter cannot reach into the next one.
function M.disable()
  pcall(vim.api.nvim_del_augroup_by_name, M.group_name)
  for _, cancel in ipairs(M._unsubscribe) do
    cancel()
  end
  M._unsubscribe = {}
end

return M
