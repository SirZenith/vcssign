--- The action layer: the only place that turns user intent into VCS commands.
---
--- Everything above it (the `:Vcssign` commands, the hunk keymaps to come)
--- asks for a *file* and an *intent*; everything below it (the adapters) runs
--- one command.  So this file is where the interesting policy lives: which file
--- an action applies to, which capability it needs, which command variant a
--- status implies (index vs worktree diff, "staged or not" for a commit), and
--- what the user is told when the answer is no.
---
--- Every action takes the same target — a `StatusEntry`, a path from a command,
--- or nothing at all (then: the file of the current buffer).
--- See impl/init/04-commands-actions.md §2.
local config = require('vcssign.config')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
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
---@field status vcssign.FileStatus?  known only when the target *was* a status entry;
---                                   a bare path is looked up when it is needed

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

--- The repository a status entry came from.
---
--- Identity, not "deepest": `entry.rel_path` is relative to the root that
--- listed the row, so when a repository is nested inside another *attached*
--- one, the deepest repository containing `entry.path` is often not the one
--- that produced the entry (an outer listing shows a nested checkout as a
--- single `?? inner/` row).  Handing a path relative to the outer root to the
--- inner repository would stage or diff the wrong tree — or nothing at all.
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
    -- A status entry: it already carries the paths, and the entry itself is
    -- what the user pointed at (so its status is the one to reason about).
    local repo = repo_of(target)
    if not repo then
      return nil, string.format('no repository for %s', target.rel_path)
    end
    return {
      repo = repo,
      path = target.path,
      rel_path = target.rel_path,
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
  -- No entry is attached: the repository no longer caches status (D38), so the
  -- one action that needs it asks the VCS through `fetch_status`.
  return {
    repo = repo,
    path = path,
    rel_path = rel,
  }
end

--- Ask the VCS what it currently thinks of a target's file, then hand the
--- `vcssign.FileStatus?` to `cb`.  A target that came from a status entry
--- already knows, so it answers synchronously; a bare path costs one status
--- command.  A failing status command is not a failing *action*: report "no
--- changes" and let the action's own command speak.
---@param t vcssign.Target
---@param cb fun(status: vcssign.FileStatus?)
local function fetch_status(t, cb)
  if t.status ~= nil then
    return cb(t.status)
  end
  t.repo.system.status(t.repo.root, function(err, entries)
    if err then
      return cb(nil)
    end
    for _, entry in ipairs(entries or {}) do
      if base.path_key(entry.path) == base.path_key(t.path) then
        return cb(entry.status)
      end
    end
    cb(nil)
  end)
end

-- ▏ diff ─────────────────────────────────────────────────────────────────────

--- The buffer a file's diff is shown in, reused across `d` presses: pressing
--- `d` twice should not leave two diff buffers behind.
---@param t vcssign.Target
---@return integer
local function diff_buffer(t)
  local name = 'vcssign://' .. t.repo.system.name .. '/' .. t.repo.root .. '/' .. t.rel_path
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
    -- Read-only: an accidental edit would make the buffer lie about the diff
    -- it is supposed to be showing.
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
--- A file whose change is *only* in the index diffs the index — `git diff
--- --cached` is the only way to see what a commit would record.  A file with
--- worktree changes diffs against the index/HEAD, which is what "what have I
--- changed since" means for an unstaged change.
---@param t vcssign.Target
---@param status vcssign.FileStatus?
---@return boolean
local function cached_diff(status)
  if status == nil then
    return false
  end
  return status.index ~= nil and status.worktree == nil
end

function M.diff(target, opts)
  local t, err = resolve(target)
  if not t then
    return fail(err)
  end
  if not t.repo.system.capabilities.diff then
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
      show_diff(t, text)
    end)
  end

  local cached = opts and opts.cached
  if cached ~= nil then
    return show(cached)
  end
  -- A file whose change is *only* in the index needs `--cached`; a file with
  -- worktree changes diffs against the index/HEAD.  Which one it is comes from
  -- the VCS, because this layer no longer has a status cache to read.
  fetch_status(t, function(status)
    show(cached_diff(status))
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
    -- Straight away, not debounced: the status has almost certainly just
    -- changed.
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

  fetch_status(t, function(status)
    if status == nil then
      return info('%s has no changes to commit', t.rel_path)
    end
    if repo.system.capabilities.stage and status.index == nil then
      return info('%s is not staged yet (press s)', t.rel_path)
    end
    if opts.message then
      commit(opts.message)
    else
      ask_message(commit)
    end
  end)
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
