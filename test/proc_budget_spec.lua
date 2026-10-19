--- A4: the process budget as a regression gate (perf §6 验收断言).
---
--- Every case here pins a **count**, never a duration: a wall clock measures the
--- machine, a process count measures the design.  The budgets come from the M7
--- measurements (perf §2.4–§2.9) with room for one debounced probe, and they are
--- set to catch the failure mode the review found — "cost per file" — not to be
--- as tight as the current implementation happens to be:
---
--- | scenario                      | git now  | git budget | svn now     | svn budget |
--- |-------------------------------|----------|------------|-------------|------------|
--- | attach 8 modified files       | 3        | 5          | —           | —          |
--- | attach 6 modified files       | —        | —          | 8 (6 `cat`) | 10         |
--- | attach a clean file           | 2        | 3          | 2           | 3          |
--- | buffer edit                   | 0        | 0          | 0           | 0          |
--- | `FocusGained`, disk unchanged | 1 / repo | 1 / repo   | 1 / repo    | 1 / repo   |
--- | external change, one file     | 1        | 2          | 1           | 2          |
--- | stage one hunk                | 4        | 6          | —           | —          |
--- | commit one file               | 3        | 4, 0 show  | 2           | 4          |
--- | blame one line / revisit      | 1 / 0    | 1 / 0      | 1 / 0       | 1 / 0      |
---
--- Two of these are **per-VCS by nature**, which is why A4 asks for a suite each:
--- svn has no `cat-file --batch` (one `cat` per modified file is its floor) and
--- no staging area, while git's count does not depend on the file count.  Do not
--- copy git's numbers onto svn.
local api = vim.api

local actions = require('vcssign.actions')
local attach = require('vcssign.attach')
local autocmds = require('vcssign.autocmds')
local blame = require('vcssign.blame')
local config = require('vcssign.config')
local manager = require('vcssign.repo_manager')

local helpers = require('helpers')

--- Buffers a case opened, so it can close them again (in `guarded`).
---@type table<integer, true>
local touched = {}

---@param fn function
---@return function
local function guarded(fn)
  return function()
    -- The plugin's own hooks are part of the cost being measured (`FocusGained`
    -- is where a sweep comes from, `BufReadPost` is what attaches a buffer), so
    -- every case runs with them on and takes them down again afterwards.
    autocmds.setup()
    local ok, err = pcall(fn)
    for bufnr in pairs(touched) do
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    touched = {}
    attach.forget_all()
    manager.dispose_all()
    autocmds.disable()
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- The budgets, in one place.
---
--- `focus` is per repository (every attached repository re-probes once), the rest
--- are absolute for the scenario each case builds.
---@type table<string, table<string, integer>>
local BUDGET = {
  -- current: attach 3 / clean 2 / focus 1 / external 1 / stage 4 / commit 3 / blame 1
  git = { attach = 5, clean = 3, focus = 1, external = 2, stage = 6, commit = 4, blame = 1 },
  -- svn pays one `cat` per modified file (no batch protocol) and has no staging
  -- area, so only its *excess* over "one per file" would be a regression.
  svn = { attach = 10, clean = 3, focus = 1, external = 2, commit = 4, blame = 1 },
}

local KINDS = { 'git', 'svn' }

--- A repository (either kind) whose files are all *modified*, plus their names.
---
--- `count` files are committed and then rewritten, so every one of them needs a
--- baseline: that is the worst case for "cost per file", which is what the
--- budget is about.
---@param kind 'git'|'svn'
---@param count integer
---@return string dir, string[] files
local function dirty_repo(kind, count)
  local dir
  if kind == 'git' then
    dir = helpers.scratch_dir('budget-git')
    helpers.sh({ 'git', 'init', '-q', '-b', 'main', dir })
    helpers.sh({ 'git', '-C', dir, 'config', 'user.email', 't@t' })
    helpers.sh({ 'git', '-C', dir, 'config', 'user.name', 't' })
  else
    dir = helpers.svn_repo('budget-svn')
  end
  local files = {}
  for i = 1, count do
    files[i] = string.format('f%d.txt', i)
    helpers.write(dir .. '/' .. files[i], 'base ' .. i .. '\n')
  end
  if kind == 'git' then
    helpers.sh({ 'git', '-C', dir, 'add', '-A' })
    helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'base' })
  else
    helpers.sh({ 'svn', 'add', '-q', '--force', dir })
    helpers.sh({ 'svn', 'commit', '-q', '-m', 'base', dir })
  end
  for i = 1, count do
    helpers.write(dir .. '/' .. files[i], 'changed ' .. i .. '\n')
  end
  return dir, files
end

--- Open `path` and attach it, waiting until the baseline is in.
---@param path string
---@return integer bufnr
local function open_attached(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = api.nvim_get_current_buf()
  touched[bufnr] = true
  attach.attach(bufnr)
  helpers.wait_for(function()
    local st = attach.state(bufnr)
    return st ~= nil and st.attached and st.buf_text ~= nil
  end, 'the buffer to attach')
  return bufnr
end

--- Count `M._render` entries per buffer from now on.
---
--- Entering is what a refresh costs even when the short-circuit then returns
--- (M7 P0-4), so the entry count is the honest measure of "how many buffers did
--- this touch".
---@return table<integer, integer> seen, fun() stop
local function watch_renders()
  local real = attach._render
  local seen = {}
  attach._render = function(st, ...)
    seen[st.bufnr] = (seen[st.bufnr] or 0) + 1
    return real(st, ...)
  end
  return seen, function()
    attach._render = real
  end
end

---@param cond boolean
---@param yes integer
---@param no integer
---@return integer
local function if_else(cond, yes, no)
  return cond and yes or no
end

--- Wait for quiescence: 10 idle polls in a row (500 ms), so a debounced probe
--- that the scenario itself provoked is counted rather than missed.
---@param max_ms? integer
local function settle(max_ms)
  local deadline = vim.uv.now() + (max_ms or 5000)
  local quiet = 0
  while vim.uv.now() < deadline and quiet < 10 do
    vim.wait(50)
    local busy = false
    for _, repo in ipairs(manager.all()) do
      if repo.is_updating or repo.is_dirty then
        busy = true
      end
    end
    quiet = if_else(busy, 0, quiet + 1)
  end
end

--- Drop everything a per-kind loop iteration attached, so the next kind starts
--- from zero repositories.
local function reset_repositories()
  settle()
  attach.forget_all()
  manager.dispose_all()
end

--- Answer `vim.ui.input` (the commit prompt) without a person.
---@param value string
---@param fn function
local function with_input(value, fn)
  local real = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm(value)
  end
  local ok, err = pcall(fn)
  vim.ui.input = real
  if not ok then
    error(err, 0)
  end
end

return {
  -- ▏ the batch cost the review was about ───────────────────────────────────
  {
    name = 'attaching modified files does not cost processes per file',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        local count = kind == 'git' and 8 or 6
        local dir, files = dirty_repo(kind, count)
        local calls = helpers.spawns(function()
          for _, name in ipairs(files) do
            open_attached(dir .. '/' .. name)
          end
          settle()
        end, dir)
        local budget = BUDGET[kind].attach
        ok(
          #calls <= budget,
          string.format('%s: %d processes for %d files, budget %d', kind, #calls, count, budget)
        )
        if kind == 'git' then
          eq(#helpers.running(calls, 'show'), 0, 'no per-file `show`: one reader serves them all')
          eq(#helpers.running(calls, 'cat-file'), 1, 'one resident reader for the repository')
        else
          -- svn's floor is one `cat` per modified file (no batch protocol); a
          -- second one per file, or a baseline read for a clean file, is the
          -- regression this catches.
          ok(
            #helpers.running(calls, 'cat') <= count,
            string.format(
              'svn: %d baseline reads for %d files',
              #helpers.running(calls, 'cat'),
              count
            )
          )
        end
        reset_repositories()
      end
    end),
  },
  -- ▏ the zero cases ────────────────────────────────────────────────────────
  {
    name = 'a clean file is attached without reading a baseline',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        local dir, files = dirty_repo(kind, 3)
        -- Put one file back to the state the repository already has: the status
        -- view says "nothing to see", so no baseline is needed at all.
        helpers.write(dir .. '/' .. files[1], 'base 1\n')
        local calls = helpers.spawns(function()
          open_attached(dir .. '/' .. files[1])
          settle()
        end, dir)
        local forbidden = kind == 'git' and 'show' or 'cat'
        eq(#helpers.running(calls, forbidden), 0, kind .. ': a clean file needs no ' .. forbidden)
        ok(
          #calls <= BUDGET[kind].clean,
          string.format('%s: %d processes to open a clean file', kind, #calls)
        )
        reset_repositories()
      end
    end),
  },
  {
    name = 'a buffer edit and an idle focus sweep spawn nothing',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        local dir, files = dirty_repo(kind, 3)
        local bufnr = open_attached(dir .. '/' .. files[1])
        settle()

        local edit = helpers.spawns(function()
          api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'edited in the buffer' })
          settle()
        end, dir)
        eq(#edit, 0, kind .. ': a buffer edit spawns nothing (the baseline cannot have moved)')

        -- `FocusGained` is the sweep a user triggers just by coming back to the
        -- terminal; with nothing changed on disk it must cost one liveness probe
        -- per repository and nothing per buffer.
        local seen, stop = watch_renders()
        local calls = helpers.spawns(function()
          vim.api.nvim_exec_autocmds('FocusGained', {})
          settle()
        end, dir)
        stop()
        local repos = #manager.all()
        ok(
          #calls <= BUDGET[kind].focus * repos,
          string.format(
            '%s: the focus sweep spawned %d processes for %d repo(s)',
            kind,
            #calls,
            repos
          )
        )
        ok(
          vim.tbl_count(seen) <= #attach.buffers(),
          string.format(
            '%s: %d buffers were entered, %d are attached',
            kind,
            vim.tbl_count(seen),
            #attach.buffers()
          )
        )
        reset_repositories()
      end
    end),
  },
  -- ▏ the event path ───────────────────────────────────────────────────────
  {
    name = 'an external change costs one buffer and one process',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        local dir, files = dirty_repo(kind, 3)
        local first = open_attached(dir .. '/' .. files[1])
        local second = open_attached(dir .. '/' .. files[2])
        settle()

        local seen, stop = watch_renders()
        local calls = helpers.spawns(function()
          helpers.write(dir .. '/' .. files[1], 'changed from outside\n')
          helpers.wait_for(function()
            return (seen[first] or 0) >= 1
          end, kind .. ': the buffer to be re-rendered')
          settle()
        end, dir)
        stop()
        ok(
          #calls <= BUDGET[kind].external,
          string.format('%s: %d processes for one changed file', kind, #calls)
        )
        eq(seen[second], nil, 'the buffer that nothing named was left alone')
        -- The buffer's own text is what the signs measure, and an outside write
        -- does not touch it: the baseline (the index) is what the event could
        -- have moved, and here it did not, so the hunk is still one line.
        eq(#attach.state(first).hunks, 1, 'the hunk is still measured against the buffer')
        reset_repositories()
      end
    end),
  },
  -- ▏ the action layer ─────────────────────────────────────────────────────
  {
    name = 'staging one hunk refreshes once, not twice',
    fn = guarded(function()
      local dir, files = dirty_repo('git', 3)
      local bufnr = open_attached(dir .. '/' .. files[1])
      settle()

      -- One hunk action used to run two refreshes (the buffer's and the
      -- repository's); the budget is "the baseline read plus the probe its own
      -- index write provokes", not two rounds (perf P1-1).
      local staged = helpers.spawns(function()
        helpers.capture_notify_one(function()
          actions.stage_hunk(nil, { bufnr = bufnr })
        end, 'staged ' .. files[1])
        settle()
      end, dir)
      ok(
        #staged <= BUDGET.git.stage,
        string.format('git: stage_hunk spawned %d processes, budget %d', #staged, BUDGET.git.stage)
      )
      helpers.wait_for(function()
        local st = attach.state(bufnr)
        return st ~= nil and st.hunks_staged ~= nil and #st.hunks_staged == 1
      end, 'the staged layer to appear')
    end),
  },
  {
    name = 'committing a file asks the view, not the file',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        local dir, files = dirty_repo(kind, 3)
        local path = dir .. '/' .. files[1]
        open_attached(path)
        settle()
        if kind == 'git' then
          -- Something must be staged for git to have anything to commit.  The
          -- index write is followed by the plugin's own debounce, so give the
          -- view time to notice before the measured command runs.
          helpers.sh({ 'git', '-C', dir, 'add', '--', files[1] })
          settle()
        end

        -- "Is the index different from HEAD?" is answered by the status view, so
        -- committing must not compare the file with itself twice (perf P1-2).
        local committed = helpers.spawns(function()
          with_input('feat: budget', function()
            actions.commit(path)
          end, dir)
          settle()
        end)
        if kind == 'git' then
          eq(
            #helpers.running(committed, 'show'),
            0,
            'no full-text compare to answer a status question'
          )
          eq(
            (
              helpers
                .sh({ 'git', '-C', dir, 'log', '-1', '--format=%s', '--', files[1] })
                :gsub('%s+$', '')
            ),
            'feat: budget'
          )
        end
        ok(
          #committed <= BUDGET[kind].commit,
          string.format(
            '%s: commit spawned %d processes, budget %d',
            kind,
            #committed,
            BUDGET[kind].commit
          )
        )
        reset_repositories()
      end
    end),
  },
  -- ▏ blame ────────────────────────────────────────────────────────────────
  {
    name = 'blame asks about the line under the cursor, and only once',
    fn = guarded(function()
      for _, kind in ipairs(KINDS) do
        -- Attach with the annotation off, so the first `look()` below is the
        -- real first question: with it on, the initial render already blames the
        -- cursor line and the case would measure a cache hit.
        config.setup({ current_line_blame = false })
        local dir, files = dirty_repo(kind, 3)
        local bufnr = open_attached(dir .. '/' .. files[1])
        settle()
        config.setup({
          current_line_blame = true,
          current_line_blame_opts = { delay = 1, virt_text_pos = 'eol' },
        })

        local function look()
          api.nvim_win_set_cursor(0, { 1, 0 })
          blame.render(bufnr)
          helpers.wait_for(function()
            return vim.b[bufnr].vcssign_blame_line ~= nil
          end, kind .. ': the annotation')
        end

        local first = helpers.spawns(look, dir)
        ok(
          #first <= BUDGET[kind].blame,
          string.format('%s: %d processes for one line of blame', kind, #first)
        )
        local again = helpers.spawns(look, dir)
        eq(#again, 0, kind .. ': the same line again costs nothing')
        reset_repositories()
      end
    end),
  },
}
