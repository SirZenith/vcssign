--- Sidebar specs: window/buffer lifecycle, rendering on screen, keymaps.
---
--- These use real repositories, real windows and real screen cells
--- (`helpers.screen_line`, which reads the internal screen a headless nvim still
--- maintains) — "the two sign columns are right" is a claim about what a user
--- sees, and `screenstring` is the only way to check it.
--- See impl/init/03-sidebar-ui.md §2, §5, §6.
local config = require('vcssign.config')
local helpers = require('helpers')
local keymap = require('vcssign.sidebar.keymap')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local repo_mod = require('vcssign.repo')
local sidebar = require('vcssign.sidebar')
local vcs = require('vcssign.vcs')

--- Back to a clean editor between cases: no sidebars, no repositories, no
--- splits, no stubbed action module.
local function reset()
  sidebar.forget_all()
  manager.dispose_all()
  if #vim.api.nvim_tabpage_list_wins(0) > 1 then
    vim.cmd('only')
  end
  package.loaded['vcssign.actions'] = nil
  package.preload['vcssign.actions'] = nil
end

--- Wrap a case body so it cleans up after itself whether it passes or fails.
---
--- `reset()` at the end of a case only runs on the happy path; a failing case
--- would leave its sidebar, repository and stubbed modules behind for the next
--- one (the failures that are hardest to read are the cascading ones).
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    reset()
    if not ok then
      error(err, 0)
    end
  end
end

--- Attach `ref` to the repository containing `path` and wait for the first
--- status run.
---@param ref string
---@param path string
---@return vcssign.Repo
local function attach_ready(ref, path)
  local err, repo = helpers.wait(function(cb)
    manager.attach(ref, path, cb)
  end)
  if not repo then
    error('attach failed: ' .. tostring(err), 2)
  end
  return repo
end

---@param repo vcssign.Repo
---@return vcssign.SidebarState, integer bufnr, integer win
local function open_sidebar(repo)
  local win = sidebar.open(repo)
  local state = assert(sidebar.state(repo), 'sidebar state')
  local bufnr = state.bufnr
  helpers.wait_for(function()
    for _, item in ipairs(renderer.items(bufnr)) do
      if item.kind == 'entry' then
        return true
      end
    end
    return false
  end, 'the sidebar to list at least one file')
  return state, bufnr, win
end

--- 1-based row of the entry with `rel_path`, in the sidebar's row model.
---@param bufnr integer
---@param rel string
---@return integer
local function row_of(bufnr, rel)
  for i, item in ipairs(renderer.items(bufnr)) do
    if item.entry and item.entry.rel_path == rel then
      return i
    end
  end
  error('no row for ' .. rel)
end

--- What the window draws to the left of `path` on `row`: the vertical separator
--- plus the sign area, as cells on screen.
---@param win integer
---@param row integer
---@param path string
---@return string
local function sign_area(win, row, path)
  local line = helpers.screen_line_at(win, row)
  local at = line:find(path, 1, true)
  ok(at, string.format('expected %q on row %d, got %q', path, row, line))
  return line:sub(1, at - 1)
end

--- Row texts of the sidebar's row model.
---@param bufnr integer
---@return string[]
local function texts(bufnr)
  local out = {}
  for i, item in ipairs(renderer.items(bufnr)) do
    out[i] = item.text
  end
  return out
end

--- The sidebar of a git repo with one change in each domain.
---@param name string
---@return vcssign.Repo, string dir
local function repo_with_changes(name)
  local dir = helpers.git_repo(name)
  helpers.write(dir .. '/base.txt', 'changed\n')
  helpers.write(dir .. '/staged.txt', 'staged\n')
  helpers.write(dir .. '/both.txt', 'both\n')
  helpers.sh({ 'git', '-C', dir, 'add', 'staged.txt', 'both.txt' })
  helpers.write(dir .. '/both.txt', 'both edited again\n')
  helpers.write(dir .. '/new.txt', 'untracked\n')
  return attach_ready('spec:' .. name, dir), dir
end

---@param opts table
---@param fn function
local function with_config(opts, fn)
  local saved = vim.deepcopy(config.get())
  config.setup(opts)
  local ok, err = pcall(fn)
  config.setup(saved)
  if not ok then
    error(err, 0)
  end
end

--- Buffer-local normal-mode mappings as `lhs -> desc`.
---@param bufnr integer
---@return table<string, string>
local function mappings(bufnr)
  local out = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
    out[map.lhs] = map.desc
  end
  return out
end

return {
  {
    name = 'opening a sidebar creates a buffer and a window for the repository',
    fn = guarded(function()
      reset()
      local repo, dir = repo_with_changes('sidebar-open')
      local _, bufnr, win = open_sidebar(repo)

      eq(vim.api.nvim_buf_get_name(bufnr), 'vcssign://git/' .. dir:gsub(':', '%%3A'), 'buffer name')
      eq(vim.bo[bufnr].buftype, 'nofile')
      eq(vim.bo[bufnr].bufhidden, 'hide', 'the buffer survives its window')
      eq(vim.bo[bufnr].filetype, 'vcssign')
      eq(vim.bo[bufnr].modifiable, false, 'the list is not user-editable')
      eq(vim.bo[bufnr].swapfile, false)

      eq(vim.wo[win].signcolumn, 'yes:2', 'two sign columns')
      eq(vim.wo[win].number, false)
      eq(vim.wo[win].wrap, false)
      eq(vim.wo[win].foldenable, false)
      eq(vim.wo[win].spell, false)
      eq(vim.wo[win].winfixwidth, true)
      eq(vim.api.nvim_win_get_width(win), config.get().sidebar.width)
      ok(vim.api.nvim_win_get_position(win)[2] >= vim.o.columns / 2, 'the default position is the right edge')
      eq(#vim.api.nvim_tabpage_list_wins(0), 2, 'the sidebar splits, it does not replace the window')
      eq(vim.api.nvim_get_current_win(), win, 'open focuses the sidebar')
    end),
  },
  {
    name = 'the list groups by status and puts the state characters in two columns',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-list')
      local _, bufnr, win = open_sidebar(repo)

      eq(texts(bufnr), {
        '── Staged (2) ──',
        'both.txt',
        'staged.txt',
        '── Unstaged (1) ──',
        'base.txt',
        '── Untracked (1) ──',
        'new.txt',
      })

      -- The sign area, straight off the screen: index state left, worktree
      -- state right (porcelain's XY), one blank column pair for single-domain
      -- rows.
      eq(sign_area(win, row_of(bufnr, 'both.txt'), 'both.txt'), '│ A M')
      eq(sign_area(win, row_of(bufnr, 'staged.txt'), 'staged.txt'), '│ A  ')
      eq(sign_area(win, row_of(bufnr, 'base.txt'), 'base.txt'), '│ M  ')
      eq(sign_area(win, row_of(bufnr, 'new.txt'), 'new.txt'), '│ U  ')

      -- Headers are not entries: the keymap layer must never act on one.
      eq(renderer.item_at(bufnr, 0).kind, 'header')
      eq(renderer.entry_at(bufnr, 0), nil)
      eq(renderer.entry_at(bufnr, 1).rel_path, 'both.txt')

      -- One column only (a user override): the indexed state is the survivor.
      vim.wo[win].signcolumn = 'yes'
      eq(sign_area(win, row_of(bufnr, 'both.txt'), 'both.txt'), '│ A')
      eq(sign_area(win, row_of(bufnr, 'base.txt'), 'base.txt'), '│ M')
    end),
  },
  {
    name = 'an svn working copy renders one flat list with a single domain',
    fn = guarded(function()
      reset()
      local dir = helpers.svn_checkout('sidebar-svn')
      helpers.write(dir .. '/base.txt', 'changed\n')
      helpers.write(dir .. '/unknown.txt', 'unknown\n')
      local repo = attach_ready('spec:sidebar-svn', dir)
      local _, bufnr, win = open_sidebar(repo)

      eq(texts(bufnr), { 'base.txt', 'unknown.txt' }, 'no Staged/Unstaged split without an index')
      for _, item in ipairs(renderer.items(bufnr)) do
        eq(item.kind, 'entry', 'no group headers for svn')
      end
      eq(sign_area(win, row_of(bufnr, 'base.txt'), 'base.txt'), '│ M  ')
      eq(sign_area(win, row_of(bufnr, 'unknown.txt'), 'unknown.txt'), '│ U  ')
    end),
  },
  {
    name = 'toggle closes a focused sidebar, focuses an unfocused one and reuses the buffer',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-toggle')
      local state, bufnr, win = open_sidebar(repo)

      sidebar.toggle(repo)
      eq(sidebar.is_open(repo), false, 'a focused sidebar closes')
      eq(vim.api.nvim_buf_is_valid(bufnr), true, 'the buffer stays behind')
      eq(sidebar.state(repo).bufnr, bufnr)

      -- Reopening is instant: same buffer, list still there, no placeholder.
      local main = vim.api.nvim_get_current_win()
      local reopened = sidebar.open(repo)
      eq(sidebar.bufnr(repo), bufnr, 'the buffer is reused, not rebuilt')
      eq(renderer.item_at(bufnr, 1).entry.rel_path, 'both.txt', 'the cached list is rendered again')

      -- Unfocused: toggle focuses instead of closing.
      vim.api.nvim_set_current_win(main)
      sidebar.toggle(repo)
      eq(sidebar.is_open(repo), true, 'an unfocused sidebar stays open')
      eq(vim.api.nvim_get_current_win(), reopened, 'and takes focus')
      eq(vim.api.nvim_get_current_win(), sidebar.win(repo))

      sidebar.close(repo)
      eq(sidebar.is_open(repo), false, 'close only closes the window')
      eq(vim.api.nvim_buf_is_valid(bufnr), true)
      eq(state.bufnr, bufnr)
    end),
  },
  {
    name = 'a disposed repository takes its sidebar window and buffer with it',
    fn = guarded(function()
      reset()
      local before = helpers.uv_count('fs_event')
      local dir = helpers.git_repo('sidebar-dispose')
      helpers.write(dir .. '/base.txt', 'changed\n')
      local repo = attach_ready('spec:sidebar-dispose', dir)
      ok(helpers.uv_count('fs_event') > before, 'the repository is being watched')
      local _, bufnr, win = open_sidebar(repo)

      -- The sidebar holds a reference of its own (D18): releasing the spec's
      -- reference is not enough to take the repository away, because the list
      -- the user is looking at still needs it.  Before M4 this was the other
      -- way round, and closing the last file of a repository silently tore down
      -- the sidebar the user was reading.
      manager.detach('spec:sidebar-dispose')
      eq(manager.count(), 1, 'the sidebar keeps its repository alive')
      ok(sidebar.state(repo) ~= nil)

      -- Only the session teardown takes it away — and then the window, buffer,
      -- subscriptions and watcher all go with it.
      manager.dispose_all()
      helpers.wait_for(function()
        return sidebar.state(repo) == nil
      end, 'the sidebar to be forgotten')

      eq(vim.api.nvim_win_is_valid(win), false, 'the window is gone')
      eq(vim.api.nvim_buf_is_valid(bufnr), false, 'the buffer is gone')
      eq(helpers.uv_count('fs_event'), before, 'and the watcher with them')
    end),
  },
  {
    name = 'the cursor stays on its file when rows appear above it',
    fn = guarded(function()
      reset()
      local dir = helpers.git_repo('sidebar-cursor')
      helpers.write(dir .. '/base.txt', 'changed\n')
      helpers.write(dir .. '/zzz.txt', 'zzz\n')
      local repo = attach_ready('spec:sidebar-cursor', dir)
      local _, bufnr, win = open_sidebar(repo)

      helpers.wait_for(function()
        local item = renderer.item_at(bufnr, 3)
        return item ~= nil and item.text == 'zzz.txt'
      end, 'zzz.txt to be the last row')
      vim.api.nvim_win_set_cursor(win, { row_of(bufnr, 'zzz.txt'), 0 })

      -- `aaa.txt` sorts before `zzz.txt`, so the row moves down by one.  A
      -- cursor restored by row number would now point at the wrong file.
      helpers.write(dir .. '/aaa.txt', 'aaa\n')
      helpers.wait_for(function()
        local item = renderer.item_at(bufnr, 4)
        return item ~= nil and item.text == 'zzz.txt'
      end, 'the new row to be inserted above the cursor')

      local cursor = vim.api.nvim_win_get_cursor(win)[1]
      eq(renderer.entry_at(bufnr, cursor - 1).rel_path, 'zzz.txt', 'the cursor followed its file')
    end),
  },
  {
    name = 'the first paint says it is refreshing, then shows the list',
    fn = guarded(function()
      reset()
      local dir = helpers.git_repo('sidebar-placeholder')
      helpers.write(dir .. '/base.txt', 'changed\n')
      -- A repo that has not run a status command yet: exactly what a sidebar
      -- opened during `attach` sees.
      local repo = repo_mod.new(vcs.get('git'), dir)
      local win = sidebar.open(repo)
      local bufnr = sidebar.bufnr(repo)

      local first = renderer.items(bufnr)[1]
      eq(first.kind, 'banner')
      ok(first.text:find('refreshing', 1, true), first.text)
      ok(helpers.screen_line_at(win, 1):find('refreshing', 1, true), 'the placeholder is on screen')

      helpers.wait_for(function()
        return repo.has_loaded
      end, 'the first refresh to finish')
      helpers.wait_for(function()
        -- Rows are 0-based in the renderer's API (`items()[1]` is the first
        -- line), so ask the model for its first row directly.
        return renderer.items(bufnr)[1].kind == 'header'
      end, 'the list to replace the placeholder')
      eq(#renderer.items(bufnr), 2, 'one group header plus one file')
      repo:dispose()
    end),
  },
  {
    name = 'a failed first run shows its reason instead of a list',
    fn = guarded(function()
      reset()
      -- Outside any repository: `git status` fails, and the sidebar has nothing
      -- but the error to show.
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, 'p')
      with_config({ sidebar = { width = 200 } }, function()
        -- The repository runtime logs the failure too; capture it so an
        -- *unexpected* warning stays visible in the suite's stderr.
        helpers.capture_notify(function()
          local repo = repo_mod.new(vcs.get('git'), dir)
          local win = sidebar.open(repo)
          helpers.wait_for(function()
            return repo.last_error ~= nil
          end, 'the failing status run')

          local item = renderer.items(sidebar.bufnr(repo))[1]
          eq(item.kind, 'banner')
          ok(item.text:find('fatal', 1, true), 'the reason is in the banner: ' .. item.text)
          ok(helpers.screen_line_at(win, 1):find('fatal', 1, true), 'and on screen')
          eq(repo.has_loaded, false, 'nothing was loaded')
          repo:dispose()
        end)
      end)
      vim.fn.delete(dir, 'rf')
    end),
  },
  {
    name = 'the default keys are buffer-local and work by pressing them',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-keys')
      local _, bufnr, win = open_sidebar(repo)

      local map = mappings(bufnr)
      eq(map['<CR>'], 'vcssign: open')
      eq(map['t'], 'vcssign: open_tab')
      eq(map['d'], 'vcssign: diff')
      eq(map['s'], 'vcssign: stage')
      eq(map['u'], 'vcssign: unstage')
      eq(map['r'], 'vcssign: refresh')
      eq(map['q'], 'vcssign: close')
      eq(map['?'], 'vcssign: help')

      -- In another buffer the same keys mean nothing to us.
      eq(mappings(vim.api.nvim_create_buf(false, true))['q'], nil, 'the mapping is buffer-local')

      local refreshes = 0
      repo.refresh_now = function()
        refreshes = refreshes + 1
      end
      vim.api.nvim_feedkeys('r', 'x', false)
      eq(refreshes, 1, "pressing 'r' refreshes")
      vim.api.nvim_feedkeys('q', 'x', false)
      eq(sidebar.is_open(repo), false, "pressing 'q' closes the sidebar")
      eq(vim.api.nvim_win_is_valid(win), false, 'the window is gone')
      eq(sidebar.state(repo).win, nil, 'and the state does not keep a dead window number')
    end),
  },
  {
    name = 'an entry action is handed to the actions layer, not built here',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-actions')
      local _, bufnr, win = open_sidebar(repo)
      vim.api.nvim_win_set_cursor(win, { row_of(bufnr, 'base.txt'), 0 })

      local calls = {}
      local function record(name)
        return function(entry, opts)
          calls[#calls + 1] = { name, entry.rel_path, opts }
        end
      end
      package.loaded['vcssign.actions'] = {
        open = record('open'),
        diff = record('diff'),
        stage = record('stage'),
        unstage = record('unstage'),
      }

      local ctx = { repo = repo, bufnr = bufnr }
      keymap.dispatch('open', ctx)
      keymap.dispatch('open_tab', ctx)
      keymap.dispatch('diff', ctx)
      keymap.dispatch('stage', ctx)
      keymap.dispatch('unstage', ctx)

      eq(calls, {
        { 'open', 'base.txt', nil },
        { 'open', 'base.txt', { tab = true } },
        { 'diff', 'base.txt', nil },
        { 'stage', 'base.txt', nil },
        { 'unstage', 'base.txt', nil },
      })

      -- Header rows have no file, so the action refuses politely.
      vim.api.nvim_win_set_cursor(win, { 1, 0 })
      local captured = helpers.capture_notify(function()
        keymap.dispatch('open', ctx)
      end)
      eq(captured[1].message, 'vcssign: no file on this line')
      eq(captured[1].level, vim.log.levels.INFO)

      -- And a key whose handler is missing is reported, not silently swallowed.
      package.loaded['vcssign.actions'] = { open = function() end }
      captured = helpers.capture_notify(function()
        vim.api.nvim_win_set_cursor(win, { row_of(bufnr, 'base.txt'), 0 })
        keymap.dispatch('stage', ctx)
      end)
      ok(captured[1].message:find("'stage'", 1, true), captured[1].message)
      package.loaded['vcssign.actions'] = nil

      -- And a install where the action layer is missing *entirely* (a partial
      -- checkout, a file that did not survive an upgrade) is reported as "not
      -- implemented yet" rather than as a load failure — the two need different
      -- reactions from the user.  Simulated by hiding the module path, since
      -- M4 genuinely ships `vcssign.actions`.
      package.loaded['vcssign.actions'] = nil
      local saved_path = package.path
      package.path = ''
      captured = helpers.capture_notify(function()
        keymap.dispatch('open', ctx)
      end)
      package.path = saved_path
      eq(captured[1].message, "vcssign: the 'open' action is not implemented yet")
    end),
  },
  {
    name = 'the capability gate explains a missing staging area before anything runs',
    fn = guarded(function()
      reset()
      local dir = helpers.svn_checkout('sidebar-gate')
      helpers.write(dir .. '/base.txt', 'changed\n')
      local repo = attach_ready('spec:sidebar-gate', dir)
      local _, bufnr, win = open_sidebar(repo)
      vim.api.nvim_win_set_cursor(win, { 1, 0 })

      local ran = false
      package.loaded['vcssign.actions'] = {
        stage = function()
          ran = true
        end,
        unstage = function()
          ran = true
        end,
      }
      local ctx = { repo = repo, bufnr = bufnr }
      local captured = helpers.capture_notify(function()
        keymap.dispatch('stage', ctx)
        keymap.dispatch('unstage', ctx)
      end)
      eq(#captured, 2, 'one message per key press')
      eq(captured[1].message, 'svn: no staging area')
      eq(captured[2].message, 'svn: no staging area')
      eq(captured[1].level, vim.log.levels.INFO, 'a missing capability is not an error')
      eq(ran, false, 'the gate fires before any command is built')
    end),
  },
  {
    name = 'the help key lists the effective mappings',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-help')
      local _, bufnr = open_sidebar(repo)
      local captured = helpers.capture_notify(function()
        keymap.dispatch('help', { repo = repo, bufnr = bufnr })
      end)
      local help = captured[1].message
      for lhs, action in pairs(config.get().sidebar.keymaps) do
        ok(help:find(lhs, 1, true), lhs .. ' is listed:\n' .. help)
        ok(help:find(action, 1, true), action .. ' is listed:\n' .. help)
      end
    end),
  },
  {
    name = 'keymap overrides are respected, including disabling a key',
    fn = guarded(function()
      reset()
      with_config({ sidebar = { keymaps = { q = false, x = 'close' } } }, function()
        local repo = repo_with_changes('sidebar-keys-override')
        local _, bufnr, win = open_sidebar(repo)
        local map = mappings(bufnr)
        eq(map['q'], nil, 'a disabled key is not mapped')
        eq(map['x'], 'vcssign: close', 'a custom key is mapped')
        eq(map['<CR>'], 'vcssign: open', 'the other defaults survive')
        vim.api.nvim_feedkeys('x', 'x', false)
        eq(sidebar.is_open(repo), false, 'the custom key does what it says')
        eq(vim.api.nvim_win_is_valid(win), false)
      end)
    end),
  },
  {
    name = 'position = "left" puts the sidebar on the left of the current window',
    fn = guarded(function()
      reset()
      with_config({ sidebar = { position = 'left', width = 30 } }, function()
        local repo = repo_with_changes('sidebar-left')
        local main = vim.api.nvim_get_current_win()
        local main_buffer = vim.api.nvim_win_get_buf(main)
        local _, _, win = open_sidebar(repo)

        eq(vim.api.nvim_win_get_position(win)[2], 0, 'the sidebar owns column 0')
        eq(vim.api.nvim_win_get_width(win), 30)
        ok(vim.api.nvim_win_get_position(main)[2] > 0, 'the edited window moved right')
        eq(vim.api.nvim_win_get_buf(main), main_buffer, 'and kept its buffer')
      end)
    end),
  },
  {
    name = 'position = "float" is refused out loud and falls back to the right edge',
    fn = guarded(function()
      reset()
      with_config({ sidebar = { position = 'float' } }, function()
        local repo = repo_with_changes('sidebar-float')
        local captured = helpers.capture_notify(function()
          sidebar.open(repo)
        end)
        eq(#captured, 1, 'the user is told')
        eq(captured[1].level, vim.log.levels.WARN)
        ok(captured[1].message:find('float', 1, true), captured[1].message)
        ok(captured[1].message:find('right', 1, true), 'and what happened instead: ' .. captured[1].message)
        local win = sidebar.win(repo)
        ok(vim.api.nvim_win_get_position(win)[2] >= vim.o.columns / 2, 'the sidebar is on the right')
      end)
    end),
  },
  {
    name = 'resizing the sidebar re-renders the truncated paths',
    fn = guarded(function()
      reset()
      with_config({ sidebar = { group_by = 'none' } }, function()
        local dir = helpers.git_repo('sidebar-resize')
        helpers.write(dir .. '/src/a-deeply-nested/directory/with-a-long-file-name.txt', 'x\n')
        local repo = attach_ready('spec:sidebar-resize', dir)
        local _, bufnr, win = open_sidebar(repo)

        -- Both events are watched: `WinResized` is what `:vertical resize` and a
        -- mouse drag fire (0.9+), `VimResized` what a terminal resize fires.
        local events = {}
        for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = 'vcssign_sidebar' })) do
          events[autocmd.event] = true
        end
        eq(events['WinResized'], true, 'a manual resize is listened to')
        eq(events['VimResized'], true, 'and a terminal resize')

        vim.api.nvim_win_set_cursor(win, { 1, 0 })
        local before = renderer.items(bufnr)[1].text
        ok(before:sub(1, 3) == '…', 'the default width already truncates: ' .. before)

        -- A headless editor never emits either event (verified: not after a
        -- `vim.wait` either, and `vim.o.columns = 100` does not help), so the
        -- handler is driven the way the autocmd drives it.  Without the repaint
        -- the old truncation stays on screen until the next refresh.
        vim.cmd('vertical resize 20')
        eq(vim.api.nvim_win_get_width(win), 20)
        vim.api.nvim_exec_autocmds('WinResized', {})
        local after = renderer.items(bufnr)[1].text
        ok(vim.fn.strchars(after) < vim.fn.strchars(before), 'the row is narrower now: ' .. after)
        ok(after:find('file-name.txt', 1, true), 'and still names the file: ' .. after)
        ok(helpers.screen_line_at(win, 1):find('file-name.txt', 1, true), 'the screen agrees')
      end)
    end),
  },
  {
    name = 'two systems on one root get one sidebar each',
    fn = guarded(function()
      reset()
      local dir = helpers.git_repo('sidebar-two-systems')
      local git_repo = repo_mod.new(vcs.get('git'), dir)
      local svn_repo = repo_mod.new(vcs.get('svn'), dir)
      sidebar.open(git_repo)
      sidebar.open(svn_repo, { enter = false })

      ok(sidebar.state(git_repo) ~= nil and sidebar.state(svn_repo) ~= nil, 'both are tracked')
      local git_buf, svn_buf = sidebar.bufnr(git_repo), sidebar.bufnr(svn_repo)
      ok(git_buf ~= svn_buf, 'two buffers, not one shared by accident')
      ok(vim.api.nvim_buf_get_name(svn_buf):find('vcssign://svn/', 1, true), 'named for its own system')

      sidebar.close(git_repo)
      eq(sidebar.is_open(git_repo), false)
      eq(sidebar.is_open(svn_repo), true, 'closing one leaves the other')
      git_repo:dispose()
      svn_repo:dispose()
    end),
  },
  {
    name = 'a failing or broken action layer is reported honestly',
    fn = guarded(function()
      reset()
      local repo = repo_with_changes('sidebar-actions-fail')
      local _, bufnr, win = open_sidebar(repo)
      vim.api.nvim_win_set_cursor(win, { row_of(bufnr, 'base.txt'), 0 })
      local ctx = { repo = repo, bufnr = bufnr }

      -- The action itself raises: the user gets an error, not silence.
      package.loaded['vcssign.actions'] = {
        open = function()
          error('kaboom')
        end,
      }
      local captured = helpers.capture_notify(function()
        keymap.dispatch('open', ctx)
      end)
      ok(captured[1].message:find('kaboom', 1, true), captured[1].message)
      eq(captured[1].level, vim.log.levels.ERROR)
      package.loaded['vcssign.actions'] = nil

      -- A module that exists but fails to load is *not* "not implemented".
      package.preload['vcssign.actions'] = function()
        error('unexpected symbol near <eof>')
      end
      captured = helpers.capture_notify(function()
        keymap.dispatch('open', ctx)
      end)
      ok(captured[1].message:find('cannot load the action layer', 1, true), captured[1].message)
      eq(captured[1].level, vim.log.levels.ERROR)
      ok(not captured[1].message:find('not implemented', 1, true), 'a load failure is not a missing feature')
      package.preload['vcssign.actions'] = nil

      -- And an action the module simply does not have is named as such.
      package.loaded['vcssign.actions'] = {}
      captured = helpers.capture_notify(function()
        keymap.dispatch('open', ctx)
      end)
      ok(captured[1].message:find("'open'", 1, true), captured[1].message)
      package.loaded['vcssign.actions'] = nil
    end),
  },
}
