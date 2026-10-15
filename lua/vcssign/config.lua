--- Plugin configuration.
---
--- Only the fields M1 (the VCS layer) needs live here; later milestones extend
--- `M.defaults` with sidebar / diff / keymap sections.
--- See impl/init/00-overview.md §3 and impl/init/01-vcs-adapter.md §6.
local M = {}

---@class vcssign.Config
---@field systems string[]           VCS systems to enable, in priority order
---@field exec_timeout_ms integer
---@field watch boolean              discover changes through the filesystem watcher
---@field update_debounce_ms integer  coalescing window for refresh requests
---@field retry_delay_ms integer     first retry delay after a failed status run
---@field retry_max_ms integer       upper bound of the exponential retry backoff
---@field log_level vcssign.LogLevel
---@field sidebar vcssign.SidebarConfig

--- Sidebar window and rendering options (impl/init/03-sidebar-ui.md).
---@class vcssign.SidebarConfig
---@field position "left"|"right"|"float"  `float` is reserved: not implemented yet
---@field width integer              columns of the split
---@field group_by "none"|"status"   `status` splits git into Staged/Unstaged/Untracked
---@field keymaps table<string, string|false>  lhs -> action name; `false` leaves a key free

---@type vcssign.Config
M.defaults = {
  systems = { 'git', 'svn' },
  exec_timeout_ms = 15000,
  watch = true,
  -- 300ms is the same order as gitsigns' `update_debounce`; long enough to
  -- swallow the event storm a single `git add` produces (measured: ~12 events
  -- on `.git`), short enough that the sidebar feels live.
  update_debounce_ms = 300,
  retry_delay_ms = 1000,
  retry_max_ms = 30000,
  log_level = 'warn',
  sidebar = {
    position = 'right',
    -- Wide enough for the two sign columns plus a readable path, and still
    -- narrower than the 80-column terminal the test suite renders into.
    width = 40,
    group_by = 'status',
    keymaps = {
      ['<cr>'] = 'open',
      t = 'open_tab',
      d = 'diff',
      s = 'stage',
      u = 'unstage',
      r = 'refresh',
      q = 'close',
      ['?'] = 'help',
    },
  },
}

---@type vcssign.Config
M.options = vim.deepcopy(M.defaults)

--- A table is treated as a dictionary (merged key by key) unless it is a
--- *non-empty list*, which replaces wholesale.  Empty tables count as
--- dictionaries, so `setup({ sidebar = {} })` leaves the defaults alone
--- (`vim.islist({})` is true, which would otherwise replace).
---@param t any
---@return boolean
local function is_dict(t)
  return type(t) == 'table' and (next(t) == nil or not vim.islist(t))
end

---@param default any
---@param override any
---@return any
local function merge_into(default, override)
  if is_dict(default) and is_dict(override) then
    local merged = vim.deepcopy(default)
    for key, value in pairs(override) do
      merged[key] = merge_into(default[key], value)
    end
    return merged
  end
  return vim.deepcopy(override)
end

--- Merge `opts` over `defaults` (pure; `setup` is the only caller).
---
--- Lists replace at every level: `systems = { 'svn' }` really means "only svn",
--- because `vim.tbl_deep_extend` merges lists element-wise and would produce
--- `{ 'svn', 'svn' }`.  Everything else merges key by key so a user can
--- override a single sidebar option.
---@param defaults table
---@param opts? table
---@return table
function M.merge(defaults, opts)
  return merge_into(defaults, opts or {})
end

--- Merge user options into the defaults and store the result.
---@param opts? table
---@return vcssign.Config
function M.setup(opts)
  M.options = M.merge(M.defaults, opts)
  return M.options
end

---@return vcssign.Config
function M.get()
  return M.options
end

return M
