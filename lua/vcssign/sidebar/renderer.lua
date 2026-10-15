--- Sidebar rendering: a status list becomes lines plus two sign columns.
---
--- The split matters for testing: `build` is pure (entries in, row model out,
--- no window anywhere) so the ordering and grouping rules are checked directly,
--- while `draw` is the only function that writes to a buffer.  See
--- impl/init/03-sidebar-ui.md §3.
local config = require('vcssign.config')
local status_type = require('vcssign.status_type')

local M = {}

--- Extmark namespace shared by every sidebar buffer.  A redraw clears it
--- wholesale: the list is replaced on each refresh, and a full repaint of a few
--- hundred rows is far below the debounce window (measured in the 1000-entry
--- case, 03 §6).
M.ns = vim.api.nvim_create_namespace('vcssign.sidebar')

--- Screen cells taken by the sign area: `sign_text` is always two characters
--- (`' ' .. symbol`), and `signcolumn = "yes:2"` reserves two such columns.
--- Verified with `screenstring`: body text starts 4 cells in, whether or not a
--- given row has signs.
M.sign_cells = 4

--- Never truncate a path below this, even in a comically narrow window.
M.min_text_width = 10

--- Upstream (index) signs are offset above every local sign.
---
--- Measured on 0.12.4 via `screenstring`: the *higher* priority sign lands in
--- the leftmost sign column, and it is the one kept when only one column fits.
--- The offset therefore reads like `git status --short`'s XY columns — index on
--- the left, worktree on the right — and the staged state is the one that
--- survives a narrow column.  1000 clears the largest local priority
--- (conflicted = 100), so "upstream wins" holds for every pair, not just the
--- common ones.
M.upstream_offset = 1000

local STAGED = 'Staged'
local UNSTAGED = 'Unstaged'
local UNTRACKED = 'Untracked'

--- Row model handed to the keymap/actions layer; also cached in
--- `vim.b[bufnr].vcssign_items`.
---@class vcssign.RenderItem
---@field kind "header"|"entry"|"banner"
---@field text string                  final line text (already truncated)
---@field entry vcssign.StatusEntry?   only for `kind == "entry"`
---@field group string?                only for `kind == "entry"` in grouped mode

-- ▏ highlights ────────────────────────────────────────────────────────────────

--- Default highlight groups, all defined with `default = true` so a colourscheme
--- (or the user) can override any of them without `setup` stomping on it.
--- Names follow the `Vcssign<State>` / `VcssignSign<State>` scheme M1 already
--- uses in `status_type`.  See 03 §3.4.
---@type table<string, string>  group -> link target
M.highlights = {
  VcssignAdded = 'DiffAdd',
  VcssignConflicted = 'DiagnosticError',
  VcssignDeleted = 'DiffDelete',
  VcssignError = 'DiagnosticError',
  VcssignHeader = 'Comment',
  VcssignIgnored = 'Comment',
  VcssignModified = 'DiffChange',
  VcssignRenamed = 'DiffChange',
  VcssignSignAdded = 'DiffAdd',
  VcssignSignConflicted = 'DiagnosticError',
  VcssignSignDeleted = 'DiffDelete',
  VcssignSignIgnored = 'Comment',
  VcssignSignModified = 'DiffChange',
  VcssignSignRenamed = 'DiffChange',
  VcssignSignUnknown = 'Comment',
  VcssignSignUntracked = 'DiagnosticWarn',
  VcssignUnknown = 'Comment',
  VcssignUntracked = 'DiagnosticWarn',
}

--- Define the default groups.  Idempotent and cheap (a couple of dozen
--- `nvim_set_hl` calls), and safe to call again after a colourscheme change:
--- `default = true` leaves any existing definition alone.
function M.define_highlights()
  for group, link in pairs(M.highlights) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

-- ▏ ordering ──────────────────────────────────────────────────────────────────

--- The state that represents a row: the worse of its two domains.  Used both to
--- order the list (worst first) and to colour the row, so those two can never
--- disagree.
---@param status vcssign.FileStatus
---@return vcssign.StatusType?
local function primary_status(status)
  local index, worktree = status.index, status.worktree
  if index == nil then
    return worktree
  end
  if worktree == nil then
    return index
  end
  return status_type.sign_priority(worktree) > status_type.sign_priority(index) and worktree or index
end

--- How badly a row wants attention.  The same ranking the sign column uses, so
--- "worst first" and "leftmost/kept sign" can never disagree.
---@param entry vcssign.StatusEntry
---@return integer
local function severity(entry)
  return status_type.sign_priority(primary_status(entry.status))
end

--- Copy and order by severity, then by path.
---
--- The copy is not optional: `Repo:entries()` hands out its own cache table, and
--- sorting it in place would reorder the cache every consumer sees.
---@param entries vcssign.StatusEntry[]
---@return vcssign.StatusEntry[]
local function ordered(entries)
  local list = {}
  for i, entry in ipairs(entries) do
    list[i] = entry
  end
  table.sort(list, function(a, b)
    local sa, sb = severity(a), severity(b)
    if sa ~= sb then
      return sa > sb
    end
    return a.rel_path < b.rel_path
  end)
  return list
end

--- Which group an entry belongs to.  Only meaningful when the system has an
--- index domain (git): a re-staged file shows its index state, so it counts as
--- staged even though the worktree has moved on again.
---@param entry vcssign.StatusEntry
---@return string
local function group_of(entry)
  if entry.status.index then
    return STAGED
  end
  if entry.status.worktree == 'untracked' then
    return UNTRACKED
  end
  return UNSTAGED
end

-- ▏ lines ─────────────────────────────────────────────────────────────────────

--- Keep the tail of `text` and mark the cut with an ellipsis: the file name
--- lives at the end of a path, that is the half worth keeping.
--- Counted in characters, not bytes, so a CJK or accented path is not cut in
--- the middle of a codepoint.
---@param text string
---@param width integer
---@return string
local function truncate_head(text, width)
  local chars = vim.fn.strchars(text)
  if chars <= width then
    return text
  end
  local keep = math.max(1, width - 1)
  return '…' .. vim.fn.strcharpart(text, chars - keep, keep)
end

---@param entry vcssign.StatusEntry
---@return string
local function label(entry)
  local text = entry.rel_path
  local orig = entry.status.orig_path
  if orig then
    text = text .. ' (from ' .. orig .. ')'
  end
  return text
end

--- Text budget for one row: window width minus the sign area, minus one cell of
--- breathing room so the path never touches the window border.
---@param width integer
---@return integer
local function text_width(width)
  return math.max(M.min_text_width, width - M.sign_cells - 1)
end

-- ▏ model ─────────────────────────────────────────────────────────────────────

--- Build the row model from a status list.  Pure: no buffer, no repo, no
--- `vim.b` access.
---@param entries vcssign.StatusEntry[]
---@param opts { width?: integer, group_by?: "none"|"status", has_index?: boolean }
---@return vcssign.RenderItem[]
function M.build(entries, opts)
  opts = opts or {}
  local width = text_width(opts.width or config.get().sidebar.width)
  local list = ordered(entries)
  local items = {} ---@type vcssign.RenderItem[]

  -- Grouping is a property of the *system*, not of the entries: svn has no
  -- index, so a Staged/Unstaged split would be a lie (03 §3.1).
  if (opts.group_by or config.get().sidebar.group_by) == 'status' and opts.has_index then
    for _, group in ipairs({ STAGED, UNSTAGED, UNTRACKED }) do
      local bucket = {}
      for _, entry in ipairs(list) do
        if group_of(entry) == group then
          bucket[#bucket + 1] = entry
        end
      end
      if #bucket > 0 then
        items[#items + 1] = {
          kind = 'header',
          text = truncate_head(string.format('── %s (%d) ──', group, #bucket), width),
          group = group,
        }
        for _, entry in ipairs(bucket) do
          items[#items + 1] = {
            kind = 'entry',
            text = truncate_head(label(entry), width),
            entry = entry,
            group = group,
          }
        end
      end
    end
  else
    for _, entry in ipairs(list) do
      items[#items + 1] = { kind = 'entry', text = truncate_head(label(entry), width), entry = entry }
    end
  end
  return items
end

--- Placeholder for a sidebar that has nothing to list yet: the first refresh is
--- still in flight, the last one failed, or the working copy really is clean.
--- These are three different situations and the sidebar says which.
---@param repo vcssign.Repo
---@param width integer
---@return vcssign.RenderItem?
local function placeholder(repo, width)
  local text ---@type string?
  if not repo.has_loaded then
    text = repo.last_error and ('── ' .. repo.last_error .. ' ──') or '── refreshing… ──'
  elseif #repo:entries() == 0 then
    text = '── no changes ──'
  end
  if not text then
    return nil
  end
  return { kind = 'banner', text = truncate_head(text, width) }
end

--- Rows for a repository, placeholder included.
---@param repo vcssign.Repo
---@param width? integer
---@return vcssign.RenderItem[]
function M.for_repo(repo, width)
  width = width or config.get().sidebar.width
  local items = M.build(repo:entries(), {
    width = width,
    group_by = config.get().sidebar.group_by,
    has_index = repo.system.capabilities.stage == true,
  })
  if #items == 0 then
    local fill = placeholder(repo, text_width(width))
    if fill then
      items[1] = fill
    end
  end
  return items
end

-- ▏ buffer ────────────────────────────────────────────────────────────────────

--- One entry row's two signs: the worktree state in the local column and the
--- index state in the upstream one, exactly as `git status --short` prints X
--- and Y.  A missing domain simply has no sign.
---@param bufnr integer
---@param line integer  0-indexed
---@param entry vcssign.StatusEntry
local function set_signs(bufnr, line, entry)
  local status = entry.status
  if status.worktree then
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      sign_text = ' ' .. status_type.symbol(status.worktree),
      sign_hl_group = status_type.sign_hl_group(status.worktree),
      priority = status_type.sign_priority(status.worktree),
    })
  end
  if status.index then
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      sign_text = ' ' .. status_type.symbol(status.index),
      sign_hl_group = status_type.sign_hl_group(status.index),
      priority = status_type.sign_priority(status.index) + M.upstream_offset,
    })
  end
end

--- Paint `items` into `bufnr`: lines, signs, highlights, and the row model the
--- keymap layer reads back.
---@param bufnr integer
---@param items vcssign.RenderItem[]
function M.draw(bufnr, items)
  local texts = {}
  for i, item in ipairs(items) do
    texts[i] = item.text
  end
  -- `modifiable = false` is part of the sidebar contract (the list is not user
  -- editable); the write itself has to lift it for the length of the call.
  local was_modifiable = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, texts)
  vim.bo[bufnr].modifiable = was_modifiable

  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  for row, item in ipairs(items) do
    local line = row - 1
    if item.kind == 'entry' then
      set_signs(bufnr, line, item.entry)
      -- The state characters live in the sign columns; colouring the path too
      -- makes a long list scannable without repeating them in the text.
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
        end_col = #item.text,
        hl_group = status_type.hl_group(primary_status(item.entry.status)),
      })
    else
      vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
        line_hl_group = item.kind == 'banner' and 'VcssignError' or 'VcssignHeader',
      })
    end
  end
  vim.b[bufnr].vcssign_items = items
end

--- Row model of `bufnr`, as written by the last `draw`.
---@param bufnr integer
---@return vcssign.RenderItem[]
function M.items(bufnr)
  return vim.b[bufnr].vcssign_items or {}
end

---@param bufnr integer
---@param row integer  0-indexed line
---@return vcssign.RenderItem?
function M.item_at(bufnr, row)
  return M.items(bufnr)[row + 1]
end

--- The entry under `row`, or nil when that row is a header or a placeholder.
--- This is the only way the keymap/actions layers learn "which file".
---@param bufnr integer
---@param row integer  0-indexed line
---@return vcssign.StatusEntry?
function M.entry_at(bufnr, row)
  local item = M.item_at(bufnr, row)
  return item and item.entry or nil
end

return M
