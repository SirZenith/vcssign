--- The action layer: the only place that turns user intent into VCS commands.
---
--- Everything above it (the `:Vcssign` commands, the hunk keymaps to come)
--- asks for a *file* and an *intent*; everything below it (the adapters) runs
--- one command.  So this file is where the interesting policy lives: which file
--- an action applies to, which capability it needs, which command variant the
--- configured baseline implies (`rev == 'index'` means the staging baseline),
--- whether a commit has anything staged to record, and what the user is told
--- when the answer is no.
---
--- Every action takes the same target — a path, or nothing at all (then: the
--- file of the current buffer).  Status entries are gone with the sidebar (M5)
--- and the repository no longer caches a file list (D38), so a target is always
--- resolved from the path itself.
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
      show_diff(t, text)
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
--- `show` is the whole vocabulary now (D42): a staged change is exactly "the
--- index blob differs from HEAD's".  A missing index blob means the file is
--- untracked (nothing to commit), and an unborn HEAD means everything the index
--- holds is new (all of it worth committing).
---@param t vcssign.Target
---@param cb fun(staged: boolean)
local function has_staged_change(t, cb)
  local root, rel = t.repo.root, t.rel_path
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
end

--- Commit one file.
---
--- git records what is in the *index*, so a file with nothing staged is refused
--- with a pointer at the key that fixes it (the plan deliberately rules out
--- "commit the worktree as well" — 04 §2.2).  svn has no index: its working
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
