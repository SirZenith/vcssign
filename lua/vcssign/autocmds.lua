--- Editor-wide lifecycle: when to attach, when to refresh, when to clean up.
---
--- Everything here is a *trigger*; the policy (one cache per root, reference
--- counting, debouncing a storm of refreshes into one command) lives in
--- `repo_manager` and `repo`.  Keeping the split means this file has no state
--- of its own beyond "which buffer is already attached", which is what makes it
--- safe to `setup()` twice.
--- See impl/init/04-commands-actions.md §4.
local config = require('vcssign.config')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local sidebar = require('vcssign.sidebar')

local M = {}

M.group_name = 'vcssign'

--- Buffer reference tokens, so re-entering a buffer does not attach it twice.
---
--- The plan (04 §4) puts a 100ms debounce around attach calls inside
--- `repo_manager` to absorb `BufEnter` storms.  It is done here instead, by
--- remembering what each buffer is already attached to: the storm is one
--- *buffer* being entered repeatedly, and a debounce would also delay the very
--- first attach after opening a file — which is the one the user is waiting
--- for.  `repo_manager.attach` is idempotent for `(ref, path)` anyway, so this
--- only saves work, it does not change behaviour.
---@type table<integer, string>  bufnr -> path it was attached for
M._attached = {}

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

--- Attach the repository containing `bufnr`'s file, if it has one.
---@param bufnr integer
function M.attach_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  -- Only ordinary, on-disk files belong to a repository.  A `nofile` buffer
  -- (our own sidebar, a terminal, a quickfix list) either has no name or has
  -- one that means nothing on disk.
  if vim.bo[bufnr].buftype ~= '' then
    return
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return
  end
  if M._attached[bufnr] == name then
    return
  end
  M._attached[bufnr] = name
  manager.attach('buf:' .. bufnr, name, function(err, repo)
    if not repo then
      -- Not an error: most files are not in a repository.
      M._attached[bufnr] = nil
      log.debug('buffer %d: %s', bufnr, err or 'no repository')
      return
    end
    log.debug('buffer %d attached to %s', bufnr, repo.root)
  end)
end

---@param bufnr integer
function M.detach_buffer(bufnr)
  M._attached[bufnr] = nil
  manager.detach('buf:' .. bufnr)
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

--- Create the `vcssign` augroup and wire the lifecycle events.
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
  -- reference to a repository could outlive its only buffer.
  subscribe({ 'BufDelete', 'BufWipeout' }, function(args)
    M.detach_buffer(args.buf)
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

  -- Focus is the reliable fallback on Windows, where a file changed by another
  -- program (`git checkout` in a terminal, an editor outside nvim) may produce
  -- no event we can see.  Debounced inside `Repo`, so a burst of focuses costs
  -- one status run.
  subscribe('FocusGained', function()
    for _, repo in ipairs(manager.all()) do
      repo:refresh()
    end
  end)

  -- Nothing may outlive the session: buffers first (they hold subscriptions
  -- into the repositories), then the repositories with their watchers.  The
  -- first step is guarded because the second one — releasing handles — is the
  -- part that must not be skipped: a sidebar that refuses to close (it is the
  -- last window) would otherwise leave every watcher armed at exit.
  subscribe('VimLeavePre', function()
    pcall(sidebar.forget_all)
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
  M._attached = {}
end

return M
