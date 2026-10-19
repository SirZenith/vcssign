--- Plugin configuration.
---
--- Defaults for the VCS layer, the line signs and the default keymaps; later
--- milestones extend `M.defaults` with the hunk actions themselves.
--- See impl/knowledge/overview/ §3 and impl/knowledge/vcs/ §6.
local formatter = require('vcssign.blame_formatter')

local M = {}

---@class vcssign.Config
---@field systems string[]           VCS systems to enable, in priority order
---@field exec_timeout_ms integer
---@field watch boolean              discover changes through the filesystem watcher
---@field update_debounce_ms integer  buffer-edit debounce window
---@field retry_delay_ms integer     first retry delay after a failed status run
---@field retry_max_ms integer       upper bound of the exponential retry backoff
---@field log_level vcssign.LogLevel
---@field signs vcssign.SignsConfig         signs for unstaged changes
---@field signs_staged vcssign.SignsConfig  signs for staged changes (git)
---@field signcolumn boolean         draw the sign text (gitsigns' `signcolumn`)
---@field rev string                 revision the buffer is compared against
---@field attach_to_untracked boolean
---@field max_file_length integer    buffers longer than this get no signs
---@field word_diff boolean
---@field deleted_preview boolean
---@field current_line_blame boolean
---@field current_line_blame_opts vcssign.BlameConfig
---@field keymaps table<string, string|false>  lhs -> action name; `false` disables every default mapping
---@field diff vcssign.DiffConfig
---@field commit vcssign.CommitConfig
--- Called when a repository becomes attached / detached (actions §4).  Optional,
--- looked up on every call so a later `setup()` still takes effect.
---@field on_attach? fun(repo: vcssign.Repo)
---@field on_detach? fun(repo: vcssign.Repo)

--- How a unified diff is shown and which algorithm computes it
--- (impl/archive/actions/ §2.1).
---@class vcssign.DiffConfig
---@field mode "vertical"|"split"  the diff window: a vertical split or a horizontal one
---@field use_external boolean      shell out to the VCS instead of the internal diff
---@field algorithm "myers"|"minimal"|"patience"|"histogram"  `vim.text.diff` algorithm
---@field indent_heuristic boolean  shift a diff to line up with indentation
---@field linematch boolean|integer  refine the intra-line diff inside a hunk (integer = hunk-size cap)
---@field ignore_cr_at_eol boolean  treat a trailing CR as part of the line ending

--- One sign type: the character drawn in the sign column plus optional
--- highlight overrides (`nil` means "derive the group from the sign name").
---@class vcssign.SignConfig
---@field text? string    the character shown in the sign column
---@field numhl? string   highlight group for the line number
---@field linehl? string  highlight group for the whole line
---@field culhl? string   highlight group for the cursor line

--- The signs for every hunk type (06-signs-in-signcolumn.md).
---@class vcssign.SignsConfig
---@field add vcssign.SignConfig
---@field change vcssign.SignConfig
---@field delete vcssign.SignConfig
---@field topdelete vcssign.SignConfig
---@field changedelete vcssign.SignConfig
---@field untracked vcssign.SignConfig

--- Inline blame rendering (06-signs-in-signcolumn.md).
---@class vcssign.BlameConfig
---@field delay integer        milliseconds the cursor has to stand still before the blame appears
---@field virt_text boolean    draw the annotation as virtual text (off: only `vim.b.vcssign_blame_line`)
---@field virt_text_pos string 'eol' | 'overlay' | 'right_align' | 'inline' (gitsigns' values)
---@field virt_text_priority integer  extmark priority of the annotation
---@field ignore_whitespace boolean  blame with git's `-w`: whitespace-only changes are ignored
---@field use_focus boolean    annotate the focused window only (gitsigns' behaviour)
---@field extra_opts string[]  extra arguments for `git blame`

--- Committing (impl/archive/actions/ §2.2).
---@class vcssign.CommitConfig
---@field message_input "input"|"buffer"  `buffer` is reserved: only `input` is implemented

---@type vcssign.Config
M.defaults = {
  systems = { 'git', 'svn' },
  exec_timeout_ms = 15000,
  watch = true,
  -- Buffer-edit debounce window; 200ms is the same order as gitsigns'
  -- `update_debounce`.
  update_debounce_ms = 200,
  retry_delay_ms = 1000,
  retry_max_ms = 30000,
  log_level = 'warn',
  -- The signs drawn for unstaged changes, and the separate set drawn for
  -- staged changes (git only).  The hunk names mirror gitsigns'.
  signs = {
    add = { text = '▎' },
    change = { text = '▎' },
    delete = { text = '▁' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
    untracked = { text = '┆' },
    numhl = false,
    linehl = false,
    culhl = false,
  },
  signs_staged = {
    add = { text = '▎' },
    change = { text = '▎' },
    delete = { text = '▁' },
    topdelete = { text = '‾' },
    changedelete = { text = '~' },
    untracked = { text = '┆' },
  },
  -- Whether the sign text is drawn at all (gitsigns' `signcolumn`).  vcssign
  -- never writes the window's `'signcolumn'`: the option is a *window* option,
  -- and writing it from a `WinEnter` handler fires `OptionSet` even when the
  -- value does not change -- which lands in whatever the plugin opening the
  -- window is doing.  Set `'signcolumn'` yourself; Neovim's default `'auto'`
  -- opens the column as soon as there is a sign to show.
  signcolumn = true,
  -- The baseline a buffer is compared against: the index (git) or BASE (svn),
  -- or any revision name the VCS understands.
  rev = 'index',
  attach_to_untracked = true,
  max_file_length = 40000,
  word_diff = false,
  deleted_preview = false,
  current_line_blame = false,
  -- The inline blame (gitsigns' `current_line_blame_opts`).
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = 'eol',
    virt_text_priority = 200,
    delay = 1000,
    ignore_whitespace = false,
    use_focus = true,
    extra_opts = {},
  },
  -- What the annotation says.  `vcssign.blame_formatter` expands the same
  -- placeholders as gitsigns; `_nc` is used for a line nobody has committed yet.
  current_line_blame_formatter = formatter.DEFAULT,
  current_line_blame_formatter_nc = ' Not Committed Yet ',
  -- lhs -> action name; `false` disables every default mapping.
  keymaps = {
    ['[c'] = 'prev_hunk',
    [']c'] = 'next_hunk',
    ['<leader>hs'] = 'stage_hunk',
    ['<leader>hr'] = 'reset_hunk',
    ['<leader>hS'] = 'stage_buffer',
    ['<leader>hu'] = 'undo_stage_hunk',
    ['<leader>hR'] = 'reset_buffer',
    ['<leader>hp'] = 'preview_hunk',
    ['<leader>hb'] = 'blame_line',
    ['<leader>hd'] = 'diffthis',
    ['<leader>hD'] = 'diffthis_rev',
    ['<leader>hq'] = 'setqflist',
    ['<leader>hQ'] = 'setqflist_all',
    ['<leader>tw'] = 'toggle_word_diff',
    ['<leader>tb'] = 'toggle_current_line_blame',
  },
  diff = {
    mode = 'vertical',
    -- The internal diff (`vim.text.diff`) is the default because svn has no
    -- local diff backend and one implementation keeps git and svn behaving the
    -- same.
    use_external = false,
    algorithm = 'myers',
    indent_heuristic = true,
    -- OFF by default because `linematch` is quadratic in the size of a hunk,
    -- and `true` means "every hunk, however large".  Measured on an
    -- all-changed buffer: 500 lines 1.1s, 2000 lines 69s, 5000 lines OOM.
    -- The value is also a *threshold*: an integer applies linematch only to
    -- hunks up to that many lines, which is the bounded way to turn it on
    -- (`true` is what hangs the editor on a large file).
    linematch = false,
    ignore_cr_at_eol = true,
  },
  commit = {
    -- `vim.ui.input`'s one-line prompt.  `"buffer"` (a throwaway commit
    -- buffer, gitsigns' `actions/commit.lua` style) is listed in the plan but
    -- not implemented yet: it warns and falls back.
    message_input = 'input',
  },
}

---@type vcssign.Config
M.options = vim.deepcopy(M.defaults)

--- A table is treated as a dictionary (merged key by key) unless it is a
--- *non-empty list*, which replaces wholesale.  Empty tables count as
--- dictionaries, so `setup({ signs = {} })` leaves the defaults alone
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
--- override a single option.
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
