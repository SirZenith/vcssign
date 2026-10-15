--- Sidebar windows and buffers.
---
--- One buffer *per repository root*, named `vcssign://<system>/<root>`: the
--- buffer outlives the window (`bufhidden = hide`), so `close` + `open` is
--- instant and shows the cached list while the next refresh is in flight.
--- Subscriptions live as long as the *buffer*, not the window — that is what
--- lets a repository that disappears close its sidebar even while it is hidden.
--- See impl/init/03-sidebar-ui.md §2.
local config = require('vcssign.config')
local keymap = require('vcssign.sidebar.keymap')
local log = require('vcssign.log')
local manager = require('vcssign.repo_manager')
local renderer = require('vcssign.sidebar.renderer')
local base = require('vcssign.vcs.base')

local M = {}

---@class vcssign.SidebarState
---@field root string
---@field system string
---@field repo vcssign.Repo
---@field bufnr integer
---@field win integer?              nil while closed (or after the window died)
---@field unsubscribe fun()[]

--- Live sidebars.
---@type table<string, vcssign.SidebarState>
M._states = {}

--- Map key of a sidebar: one per *system and root*, matching the buffer name.
--- The repository manager only ever holds one repository per root, but the
--- sidebar is a plain consumer of `Repo` objects — keying on the root alone
--- would let a second system's repository take over the first one's buffer
--- (whose name, after all, still says which system it belongs to).
---@param repo vcssign.Repo
---@return string
local function state_key(repo)
  return repo.system.name .. '|' .. base.path_key(repo.root)
end

--- Buffer name for a repository.
---
--- `%` is escaped first, so a path containing a literal `%3A` cannot collide
--- with one containing `:`; `\` rather than `/` keeps two distinct POSIX paths
--- apart.  `/` itself needs no escaping — it is the separator the rest of the
--- plugin uses.
---@param system string
---@param root string
---@return string
function M.bufname(system, root)
  local escaped = root:gsub('%%', '%%25'):gsub('\\', '%%5C'):gsub(':', '%%3A'):gsub(' ', '%%20')
  return 'vcssign://' .. system .. '/' .. escaped
end

---@param repo vcssign.Repo
---@return vcssign.SidebarState?
function M.state(repo)
  return M._states[state_key(repo)]
end

--- The sidebar a buffer belongs to, or nil when `bufnr` is not one.
---
--- The command layer needs this: `:Vcssign close` typed while the cursor sits
--- in a sidebar has to act on *that* sidebar, and the buffer's name
--- (`vcssign://…`) is not a path that could be resolved instead.
---@param bufnr integer
---@return vcssign.SidebarState?
function M.state_of_buf(bufnr)
  for _, state in pairs(M._states) do
    if state.bufnr == bufnr then
      return state
    end
  end
  return nil
end

--- How many sidebars are tracked, open or hidden (`:Vcssign debug`).
---@return integer
function M.count()
  return vim.tbl_count(M._states)
end

--- How many of them are on screen right now.
---@return integer
function M.open_count()
  local n = 0
  for _, state in pairs(M._states) do
    if state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
      n = n + 1
    end
  end
  return n
end

---@param repo vcssign.Repo
---@return boolean
function M.is_open(repo)
  local state = M.state(repo)
  return state ~= nil and state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

--- The sidebar buffer for `repo`, if it was ever opened.
---@param repo vcssign.Repo
---@return integer?
function M.bufnr(repo)
  local state = M.state(repo)
  return state and state.bufnr or nil
end

---@param repo vcssign.Repo
---@return integer?
function M.win(repo)
  local state = M.state(repo)
  return state and state.win or nil
end

-- ▏ window options ────────────────────────────────────────────────────────────

---@param win integer
local function set_win_options(win)
  vim.wo[win].signcolumn = 'yes:2' -- the two status columns
  vim.wo[win].number = false
  vim.wo[win].wrap = false
  vim.wo[win].foldenable = false
  vim.wo[win].spell = false
  -- The sidebar keeps its width when other windows open and close; the user can
  -- still resize it by hand.
  vim.wo[win].winfixwidth = true
end

-- ▏ rendering ─────────────────────────────────────────────────────────────────

--- Repaint a sidebar from the repository's cache.  Rows are rebuilt wholesale
--- (the list is replaced on every refresh anyway), and the cursor is put back on
--- the file it was on — by path, with the row number only as a fallback for
--- header/placeholder rows.
---@param state vcssign.SidebarState
function M._render(state)
  local win = state.win
  if win == nil or not vim.api.nvim_win_is_valid(win) then
    -- Hidden: the cached text is still there, `open` re-renders.
    return
  end
  if not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end

  local row = vim.api.nvim_win_get_cursor(win)[1]
  local previous = renderer.entry_at(state.bufnr, row - 1)
  local previous_path = previous and previous.path or nil

  local items = renderer.for_repo(state.repo, vim.api.nvim_win_get_width(win))
  renderer.draw(state.bufnr, items)

  if previous_path then
    for i, item in ipairs(items) do
      if item.entry and item.entry.path == previous_path then
        row = i
        break
      end
    end
  end
  row = math.min(row, math.max(1, #items))
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
end

--- Repaint every open sidebar: their text is width-dependent.
local function redraw_all()
  for _, state in pairs(M._states) do
    M._render(state)
  end
end

--- Window resizes change how much of a path fits, so the sidebar listens for
--- them: `VimResized` for the terminal, `WinResized` for a manual
--- `:vertical resize` / mouse drag (0.9+; `VimResized` alone would leave the
--- old truncation on screen until the next refresh).  This is the only autocmd
--- the sidebar owns; the editor-wide lifecycle (attach on BufEnter, cleanup on
--- exit) belongs to 04's `autocmds.lua`.
local resize_hook = false
local function ensure_resize_hook()
  if resize_hook then
    return
  end
  resize_hook = true
  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    group = vim.api.nvim_create_augroup('vcssign_sidebar', { clear = true }),
    desc = 'vcssign: re-render sidebars after a resize',
    callback = redraw_all,
  })
end

-- ▏ lifecycle ─────────────────────────────────────────────────────────────────

---@param state vcssign.SidebarState
local function unsubscribe(state)
  for _, cancel in ipairs(state.unsubscribe) do
    cancel()
  end
  state.unsubscribe = {}
end

--- Drop every trace of a sidebar.  The one place that knows the order in which
--- subscriptions, maps and windows have to go.
--- The manager reference a sidebar holds while its buffer exists (D18): the
--- buffer outlives its window, so the user may well have closed the last file
--- of the repository while the list is still on screen.
---@param repo vcssign.Repo
---@return string
local function ref_of(repo)
  return 'sidebar:' .. state_key(repo)
end

---@param state vcssign.SidebarState
---@param delete_buffer boolean  false from `BufWipeout`, where the buffer is
---        already going away (deleting it again would re-enter)
local function drop(state, delete_buffer)
  -- Subscriptions first: that is what makes the rest re-entrant-safe (the
  -- repository may be released — and disposed — by the line below).
  unsubscribe(state)
  manager.detach(ref_of(state.repo))
  if state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
    -- `pcall`: closing the *last* window raises (E444), and on a teardown path
    -- that would abort the rest of the cleanup.  The buffer is deleted below
    -- either way, which is what actually makes the window go.
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  state.win = nil
  M._states[state_key(state.repo)] = nil
  if delete_buffer and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
end

--- Forget a sidebar: drop the subscriptions, delete the buffer and the maps.
--- Called when the repository is gone, and when the buffer is wiped by hand.
---@param state vcssign.SidebarState
function M._forget(state)
  drop(state, true)
end

--- Create the (hidden) buffer for `repo` and wire it to the repository.
---@param repo vcssign.Repo
---@return vcssign.SidebarState
local function create(repo)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, M.bufname(repo.system.name, repo.root))
  vim.bo[bufnr].buftype = 'nofile'
  -- Keeps the buffer (and its list) around when the window closes.
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'vcssign'
  vim.b[bufnr].vcssign_items = {}

  local state = {
    root = repo.root,
    system = repo.system.name,
    repo = repo,
    bufnr = bufnr,
    win = nil,
    unsubscribe = {},
  }
  M._states[state_key(repo)] = state
  -- Held from here until `drop`, i.e. exactly as long as the buffer exists.
  manager.hold(ref_of(repo), repo)

  -- The buffer is the unit of subscription, so dropping it must drop them —
  -- otherwise a `:bwipeout` would leave listeners pointing at a dead buffer.
  -- The buffer is already on its way out here, hence `delete_buffer = false`.
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    desc = 'vcssign: forget a wiped sidebar buffer',
    callback = function()
      drop(state, false)
    end,
  })

  state.unsubscribe = {
    repo:on_update(function()
      M._render(state)
    end),
    -- An error changes the placeholder (and maybe `last_error`), so repaint.
    repo:on_error(function()
      M._render(state)
    end),
    -- The repository vanished or was disposed: the sidebar no longer has a
    -- subject, so the window and the buffer go with it.
    repo:on_delete(function()
      M._forget(state)
    end),
  }
  keymap.attach(bufnr, { repo = repo })
  return state
end

---@param state vcssign.SidebarState
local function split_position()
  local position = config.get().sidebar.position
  if position == 'float' then
    log.warn('sidebar.position = "float" is not implemented yet; using "right"')
    position = 'right'
  end
  return position == 'left' and 'left' or 'right'
end

--- Open (or focus) the sidebar of `repo`.
---@param repo vcssign.Repo
---@param opts? { enter?: boolean }  `enter = false` keeps the cursor where it is
---@return integer win
function M.open(repo, opts)
  local enter = (opts == nil or opts.enter ~= false)
  renderer.define_highlights()
  ensure_resize_hook()

  local state = M.state(repo)
  if state and state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
    if enter then
      vim.api.nvim_set_current_win(state.win)
    end
    M._render(state)
    return state.win
  end
  state = state or create(repo)
  -- A new window, showing the buffer directly: `nvim_open_win` with `split`
  -- leaves the previously focused window and its buffer untouched.
  state.win = vim.api.nvim_open_win(state.bufnr, enter, {
    split = split_position(),
    width = config.get().sidebar.width,
  })
  set_win_options(state.win)
  M._render(state)
  if not repo.has_loaded then
    -- First paint showed the placeholder; ask for the real list.  Debounced and
    -- idempotent, so racing the attach-time refresh is harmless.
    repo:refresh()
  end
  return state.win
end

--- Close the window, keeping the buffer so a reopen is instant.
---@param repo vcssign.Repo
function M.close(repo)
  local state = M.state(repo)
  if state and state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_win_close(state.win, true)
  end
  if state then
    state.win = nil
  end
end

---@param repo vcssign.Repo
function M.focus(repo)
  local state = M.state(repo)
  if state and state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
    vim.api.nvim_set_current_win(state.win)
  end
end

--- `toggle`: focused -> close, open but unfocused -> focus, closed -> open.  The
--- convention every sidebar plugin shares (gitsigns' `toggle` included).
---@param repo vcssign.Repo
function M.toggle(repo)
  local state = M.state(repo)
  if state and state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
    if vim.api.nvim_get_current_win() == state.win then
      M.close(repo)
    else
      M.focus(repo)
    end
    return
  end
  M.open(repo)
end

--- Close every sidebar window, keeping the buffers.  Used by specs and by the
--- teardown path in 04.
function M.close_all()
  for _, state in pairs(M._states) do
    if state.win ~= nil and vim.api.nvim_win_is_valid(state.win) then
      vim.api.nvim_win_close(state.win, true)
    end
    state.win = nil
  end
end

--- Forget every sidebar: subscriptions, buffers, maps.  Terminal.
function M.forget_all()
  -- Snapshot the values, not the map: dropping a state mutates it, and a deep
  -- copy would try to copy the repo (which holds libuv userdata).
  local states = {}
  for _, state in pairs(M._states) do
    states[#states + 1] = state
  end
  for _, state in ipairs(states) do
    M._forget(state)
  end
end

return M
