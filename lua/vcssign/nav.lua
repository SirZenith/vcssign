--- Hunk navigation: which line `]c` / `[c` land on.
---
--- Deliberately repository-free and buffer-content-free: the hunks a buffer
--- carries are `attach.hunks(bufnr)` (plus the staged layer), and the line a
--- hunk's sign hangs on is `signs.sign_line(h)`.  Navigation therefore cannot
--- disagree with what is on screen — it moves between marks the user can see,
--- not between offsets recomputed from the file.
---
--- Both layers are targets: after `git add`, a hunk is still visible (in the
--- staged column) and `]c` must still find it.
---
--- The shape follows gitsigns (`nav_hunk`): a *direction*, a *count* and
--- wraparound at the ends.  Wrap is not a config key — signs §4 adds none, and
--- gitsigns has none — it is the `opts.wrap` argument, default `true`.
local api = vim.api

local attach = require('vcssign.attach')
local signs = require('vcssign.signs')

local M = {}

--- The window whose cursor navigation moves, or nil when the buffer is not on
--- screen (the current window when it shows the buffer; otherwise whichever
--- window in this tabpage does).
---@param bufnr integer
---@return integer?
local function window_for(bufnr)
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) == bufnr then
    return win
  end
  local found = vim.fn.bufwinid(bufnr)
  if found == -1 then
    return nil
  end
  return found
end

--- Every hunk anchor line of `bufnr`, ascending and deduplicated.
---
--- A hunk with no anchor at all (`signs.sign_line` answers nil: an unknown
--- type) is not a landing spot; neither is a line the buffer no longer has,
--- which a stale hunk list can name between an edit and the debounced render.
---@param bufnr integer
---@return integer[] lines  1-based
function M.lines(bufnr)
  local st = attach.state(bufnr)
  local seen = {}
  local out = {}
  ---@param hunks vcssign.Hunk[]
  local function add(hunks)
    for _, h in ipairs(hunks or {}) do
      local lnum = signs.sign_line(h)
      if lnum and lnum >= 1 and lnum <= api.nvim_buf_line_count(bufnr) and not seen[lnum] then
        seen[lnum] = true
        out[#out + 1] = lnum
      end
    end
  end
  add(attach.hunks(bufnr))
  add(st and st.hunks_staged)
  table.sort(out)
  return out
end

--- 1-based position of the first entry strictly after `lnum`, or nil.
---@param lines integer[]
---@param lnum integer
---@return integer?
local function index_after(lines, lnum)
  for i, line in ipairs(lines) do
    if line > lnum then
      return i
    end
  end
  return nil
end

--- 1-based position of the last entry strictly before `lnum`, or nil.
---@param lines integer[]
---@param lnum integer
---@return integer?
local function index_before(lines, lnum)
  for i = #lines, 1, -1 do
    if lines[i] < lnum then
      return i
    end
  end
  return nil
end

--- Keep a computed position inside `1..#lines`, either by wrapping around or
--- by refusing to move.
---@param pos integer        may be < 1 or > #lines
---@param n integer          #lines, >= 1
---@param wrap boolean
---@return integer?
local function settle(pos, n, wrap)
  if pos >= 1 and pos <= n then
    return pos
  end
  if not wrap then
    return nil
  end
  return ((pos - 1) % n) + 1
end

--- Move the cursor `count` hunks from where it is.
---@param bufnr integer
---@param dir 1|string       1 = forward (`]c`), anything else = backward (`[c`)
---@param count? integer     how many hunks to cross (>= 1, default 1)
---@param opts? { wrap?: boolean }
---@return integer? lnum     the line the cursor moved to, nil when it did not
local function move(bufnr, dir, count, opts)
  count = math.max(1, math.floor(count or 1))
  local wrap = not opts or opts.wrap ~= false
  local lines = M.lines(bufnr)
  if #lines == 0 then
    return nil
  end
  local win = window_for(bufnr)
  if not win then
    return nil
  end
  local cur = api.nvim_win_get_cursor(win)[1]
  local n = #lines
  local forward = dir == 1
  -- `from` is the position the count is measured from: the hunk after /
  -- before the cursor, or nil when there is none in that direction (only a
  -- wrap can move then).  Spelled out rather than `forward and x or y`, which
  -- silently takes the wrong branch when `x` is nil.
  local from
  if forward then
    from = index_after(lines, cur)
  else
    from = index_before(lines, cur)
  end
  local pos
  if from == nil then
    -- Cursor is past the last hunk (`]c`) or before the first one (`[c`).
    if not wrap then
      return nil
    end
    pos = forward and count or (n - count + 1)
  elseif forward then
    pos = from + count - 1
  else
    pos = from - count + 1
  end
  pos = settle(pos, n, wrap)
  if not pos then
    return nil
  end
  local target = lines[pos]
  if target == cur then
    -- Already there: the only way this happens is a buffer whose single hunk
    -- is under the cursor, so a wrapped `]c` would be a no-op.  Report it as
    -- "did not move" and leave the column alone.
    return nil
  end
  api.nvim_win_set_cursor(win, { target, 0 })
  return target
end

--- Jump to the `count`-th hunk after the cursor (the `]c` mapping).
---@param bufnr integer
---@param count? integer
---@param opts? { wrap?: boolean }
---@return integer? lnum
function M.next(bufnr, count, opts)
  return move(bufnr, 1, count, opts)
end

--- Jump to the `count`-th hunk before the cursor (the `[c` mapping).
---@param bufnr integer
---@param count? integer
---@param opts? { wrap?: boolean }
---@return integer? lnum
function M.prev(bufnr, count, opts)
  return move(bufnr, -1, count, opts)
end

return M
