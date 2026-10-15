--- The action layer: the only place that turns user intent into VCS commands.
---
--- Everything above it (the sidebar's keymaps, the `:Vcssign` commands) asks
--- for a *file* and an *intent*; everything below it (the adapters) runs one
--- command.  So this file is where the interesting policy lives: which file an
--- action applies to, which capability it needs, which command variant a status
--- implies (index vs worktree diff, "staged or not" for a commit), and what the
--- user is told when the answer is no.
---
--- Every action takes the same target — a `StatusEntry` from the sidebar, a path
--- from a command, or nothing at all (then: the file of the current buffer, or
--- the entry under the cursor when the sidebar itself has focus).
--- See impl/init/04-commands-actions.md §2.
local config = require('vcssign.config')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local sidebar = require('vcssign.sidebar')
local base = require('vcssign.vcs.base')

local uv = vim.uv

local M = {}

---@param fmt string
---@param ... any
local function info(fmt, ...)
  log.notify(select('#', ...) == 0 and fmt or string.format(fmt, ...))
end

--- A system-scoped refusal (`svn: no staging area`) reads as the *system*
--- talking, and both the sidebar keys and this layer phrase it the same way —
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
---@field entry vcssign.StatusEntry?  what the VCS last said about the file
---@field status vcssign.FileStatus?

--- The entry under the cursor when the sidebar is the current buffer: that is
--- what "no argument" means for `:Vcssign stage` typed inside the sidebar.
---@return vcssign.StatusEntry?
local function sidebar_cursor_entry()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= 'vcssign' then
    return nil
  end
  return renderer.entry_at(bufnr, vim.api.nvim_win_get_cursor(0)[1] - 1)
end

--- Default target: the sidebar row under the cursor, else the current buffer's
--- file, else the cwd (a `:Vcssign refresh` from an empty scratch buffer).
---@return vcssign.StatusEntry|string
local function default_target()
  local entry = sidebar_cursor_entry()
  if entry then
    return entry
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' then
    return name
  end
  return uv.cwd() or '.'
end

--- The repository a sidebar entry came from.
---
--- Identity, not "deepest": `entry.rel_path` is relative to the root that
--- listed the row, so when a repository is nested inside another *attached*
--- one, the deepest repository containing `entry.path` is often not the one
--- that rendered the row (the outer list shows a nested checkout as a single
--- `?? inner/` row).  Handing a path relative to the outer root to the inner
--- repository would stage or diff the wrong tree — or nothing at all.
---@param entry vcssign.StatusEntry
---@return vcssign.Repo?
local function repo_of(entry)
  for _, repo in ipairs(manager.all()) do
    if base.path_key(base.abspath(repo.root, entry.rel_path)) == base.path_key(entry.path) then
      return repo
    end
  end
  return nil
end

--- Resolve a target into the repository that owns it plus the file's path.
---@param target vcssign.StatusEntry|string|nil
---@return vcssign.Target?, string? err
local function resolve(target)
  target = target or default_target()
  if type(target) == 'table' then
    -- A sidebar entry: it already carries the paths, and the entry itself is
    -- what the user pointed at (so its status is the one to reason about).
    local repo = repo_of(target)
    if not repo then
      return nil, string.format('no repository for %s', target.rel_path)
    end
    return {
      repo = repo,
      path = target.path,
      rel_path = target.rel_path,
      entry = target,
      status = target.status,
    }
  end
  local path = base.normalize(target)
  local repo = manager.get_by_path(path)
  if not repo then
    return nil, string.format('no repository for %s', path)
  end
  local rel = base.relpath(path, repo.root)
  if rel == nil then
    return nil, string.format('%s is outside %s', path, repo.root)
  end
  local entry = repo:get_entry(path)
  return {
    repo = repo,
    path = path,
    rel_path = rel,
    entry = entry,
    status = entry and entry.status or nil,
  }
end

-- ▏ open ─────────────────────────────────────────────────────────────────────

--- A window that is not showing a sidebar, or nil when every window is one.
---
--- Opening a file from the sidebar must not replace the sidebar: `:edit` in the
--- sidebar's own window would swap the list out for the file (and `bufhidden =
--- hide` would leave the list orphaned in no window at all).
---@return integer?
local function editor_window()
  ---@param win integer
  ---@return boolean
  local function usable(win)
    -- A floating window (a picker, a hover, our own future float) is not "the
    -- editor", and neither is a terminal, a quickfix list or another plugin's
    -- sidebar: `:edit` there would be a surprise.
    if vim.api.nvim_win_get_config(win).relative ~= '' then
      return false
    end
    local buf = vim.api.nvim_win_get_buf(win)
    return vim.bo[buf].buftype == '' and vim.bo[buf].filetype ~= 'vcssign'
  end

  local current = vim.api.nvim_get_current_win()
  if usable(current) then
    return current
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if usable(win) then
      return win
    end
  end
  return nil
end

--- Open a file in an editor window (never in the sidebar's own window).
---@param target vcssign.StatusEntry|string|nil
---@param opts? { tab?: boolean }
function M.open(target, opts)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  local status = t.status
  if status and (status.worktree == 'deleted' or status.worktree == 'missing') then
    -- The VCS says the file is gone; `:edit` would silently create an empty
    -- buffer that looks like a file full of nothing.
    return info('%s has been deleted', t.rel_path)
  end
  if uv.fs_stat(t.path) == nil then
    -- Either the cache is stale (an external `rm` we have not seen yet) or the
    -- file is only missing in the worktree; both mean "do not open it".
    t.repo:mark_dirty()
    return info('%s does not exist', t.rel_path)
  end

  local escaped = vim.fn.fnameescape(t.path)
  ---@type boolean, any
  local ok, err
  if opts and opts.tab then
    ok, err = pcall(vim.cmd, 'tabedit ' .. escaped)
  else
    local win = editor_window()
    if win == nil then
      -- Nothing but sidebars (and other non-ordinary windows) on screen: give
      -- the file a window of its own rather than taking the sidebar's.
      ok, err = pcall(vim.cmd, 'vsplit ' .. escaped)
    else
      vim.api.nvim_set_current_win(win)
      ok, err = pcall(vim.cmd, 'edit ' .. escaped)
    end
  end
  if not ok then
    -- `:vsplit` fails for want of room (E36), and this runs inside an async
    -- command callback: an uncaught error would surface as "Error in callback"
    -- instead of as an answer to the key the user pressed.
    fail(tostring(err))
  end
end

-- ▏ diff ─────────────────────────────────────────────────────────────────────

--- The buffer a file's diff is shown in, reused across `d` presses: pressing
--- `d` twice should not leave two diff buffers behind.
---@param t vcssign.Target
---@return integer
local function diff_buffer(t)
  local name = sidebar.bufname(t.repo.system.name, t.repo.root) .. '/' .. t.rel_path
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      if vim.api.nvim_buf_is_loaded(bufnr) then
        return bufnr
      end
      -- Left over from a `:bunload`: start over rather than write into a
      -- buffer that would have to be loaded first.
      vim.api.nvim_buf_delete(bufnr, { force = true })
      break
    end
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  -- The diff is a view, not a document: closing its window should end it.
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].filetype = 'diff'
  return bufnr
end

--- Show `text` as a unified diff in a new window.
---@param t vcssign.Target
---@param text string
local function show_diff(t, text)
  local bufnr = diff_buffer(t)
  vim.bo[bufnr].modifiable = true
  -- `trimempty` drops the empty line a trailing newline would add (a diff
  -- ends with one); empty *context* lines inside the diff are kept.
  local lines = vim.split(text, '\n', { plain = true, trimempty = true })
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  if vim.api.nvim_buf_is_valid(bufnr) then
    -- Read-only, for the sidebar's reason: an accidental edit would make
    -- the buffer lie about the diff it is supposed to be showing.
    vim.bo[bufnr].modifiable = false
  end
  if not ok then
    error(err, 0)
  end

  -- The window may already be showing this diff (the user pressed `d` twice,
  -- or came back to the file): focus it instead of stacking another split.
  local existing = vim.fn.bufwinid(bufnr)
  if existing ~= -1 then
    vim.api.nvim_set_current_win(existing)
    return
  end

  -- A sensible default size, and one place that knows which way the split
  -- goes, so the two modes cannot drift apart.
  local opts = config.get().diff.mode == 'split'
      and { split = 'below', height = math.max(10, math.floor(vim.o.lines / 2)) }
    or { split = 'right', width = math.max(40, math.floor(vim.o.columns / 2)) }
  -- Same reason as `open`: opening a window can fail (no room), and that must
  -- arrive as a message rather than as an error inside a callback.
  local opened, win = pcall(vim.api.nvim_open_win, bufnr, true, opts)
  if not opened then
    return fail(tostring(win))
  end
  vim.wo[win].wrap = false
  vim.wo[win].foldenable = false
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

--- Which side of the working copy to diff against.
---
--- A file whose change is *only* in the index (i.e. the row the user pressed
--- `d` on sits in the sidebar's Staged group) diffs the index — `git diff
--- --cached` is the only way to see what a commit would record.  A file with
--- worktree changes diffs against the index/HEAD, which is what "what have I
--- changed since" means for an unstaged row.
---@param t vcssign.Target
---@return boolean
local function cached_diff(t)
  local status = t.status
  if status == nil then
    return false
  end
  return status.index ~= nil and status.worktree == nil
end

---@param target vcssign.StatusEntry|string|nil
---@param opts? { cached?: boolean }  force one side (used by the specs and by
---        any future "show me the staged version" entry point)
function M.diff(target, opts)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  if not t.repo.system.capabilities.diff then
    return refuse('%s: diff is not supported', t.repo.system.name)
  end
  local cached = opts and opts.cached
  if cached == nil then
    cached = cached_diff(t)
  end
  t.repo.system.diff(t.repo.root, t.rel_path, { cached = cached }, function(diff_err, text)
    if diff_err then
      return fail(diff_err)
    end
    if text == nil or vim.trim(text) == '' then
      -- "No diff" is an answer, not a failure: svn prints nothing for a
      -- property-only change, and git prints nothing for an unmodified file.
      return info('%s: no changes to show', t.rel_path)
    end
    show_diff(t, text)
  end)
end

-- ▏ stage / unstage ──────────────────────────────────────────────────────────

---@param target vcssign.StatusEntry|string|nil
---@param action "stage"|"unstage"
local function stage_like(target, action)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  local repo = t.repo
  if not repo.system.capabilities[action] then
    return refuse('%s: no staging area', repo.system.name)
  end
  repo.system[action](repo.root, { t.rel_path }, function(cmd_err)
    if cmd_err then
      return fail(cmd_err)
    end
    info('%s %s', action == 'stage' and 'staged' or 'unstaged', t.rel_path)
    -- Straight away, not debounced: the user is looking at the list, and the
    -- status has almost certainly just changed (the row moves between groups).
    repo:refresh_now()
  end)
end

--- Move a file's changes into the index (git).
---@param target vcssign.StatusEntry|string|nil
function M.stage(target)
  stage_like(target, 'stage')
end

--- Take a file's changes back out of the index (git).
---@param target vcssign.StatusEntry|string|nil
function M.unstage(target)
  stage_like(target, 'unstage')
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

--- Commit one file.
---
--- git records what is in the *index*, so a file that is not staged is refused
--- with a pointer at the key that fixes it (the plan deliberately rules out
--- "commit the worktree as well" — 04 §2.2).  svn has no index: its working
--- copy is the thing being committed.
---@param target vcssign.StatusEntry|string|nil
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
  local status = t.status
  if status == nil then
    return info('%s has no changes to commit', t.rel_path)
  end
  if repo.system.capabilities.stage and status.index == nil then
    return info('%s is not staged yet (press s)', t.rel_path)
  end

  local function commit(msg)
    repo.system.commit(repo.root, { t.rel_path }, msg, function(cmd_err, summary)
      if cmd_err then
        return fail(cmd_err)
      end
      info('committed %s%s', t.rel_path, summary and summary ~= '' and (' (' .. summary .. ')') or '')
      repo:refresh_now()
    end)
  end

  if opts.message then
    commit(opts.message)
  else
    ask_message(commit)
  end
end

-- ▏ refresh ──────────────────────────────────────────────────────────────────

--- Refresh the repository of a file (or of the only attached one).
---
--- `refresh` is the one action whose argument is a *repository*, not a file, so
--- it works without a current file too — `:Vcssign refresh` from a scratch
--- buffer in a session with exactly one repository means that repository.
---@param target vcssign.StatusEntry|string|nil
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
