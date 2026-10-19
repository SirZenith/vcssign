--- The two previews of Step 10: the virtual lines that show deleted lines in
--- place, and the floating window that shows one hunk as a diff.
---
--- Both are read-only views.  Neither touches the buffer, the index or the
--- worktree, and `attach` clears both whenever it re-renders, so a preview can
--- never outlive the hunk it was made from.  The window half (`M.open` /
--- `M.close` / `M.is_open`) is the one-place float helper: Step 11's
--- `blame.lua` shows its single-line blame through it, so at most one of these
--- transient views is ever on screen.
local api = vim.api
local config = require('vcssign.config')
local hunk = require('vcssign.hunk')
local signs = require('vcssign.signs')

local M = {}

local NS = 'vcssign_preview'

--- The group of the virtual deleted lines: `DiffDelete` is what a colorscheme
--- already paints removed lines with in a diff window.
local VIRT_GROUP = 'VcssignDeleteVirtLn'

function M.define_highlights()
  api.nvim_set_hl(0, VIRT_GROUP, { link = 'DiffDelete', default = true })
end

---@type integer?
M._ns = nil

--- The namespace the deleted-line preview lives in (`vcssign_preview`, signs §4).
---@return integer
function M.namespace()
  if not M._ns then
    M._ns = api.nvim_create_namespace(NS)
  end
  return M._ns
end

--- One hunk as the lines of a unified diff, uncoloured: the `@@` header and the
--- removed / added lines.
---
--- `git diff` and `svn diff` print exactly this shape, and the preview window
--- sets `filetype=diff` so the colorscheme's diff syntax does the colouring —
--- no highlight group of ours has to guess what a removed line looks like.
---@param h vcssign.Hunk
---@param base_lines string[]
---@param buf_lines string[]
---@return string[]
function M.hunk_text(h, base_lines, buf_lines)
  local lines = hunk.lines_of(h, base_lines, buf_lines)
  local text = {
    string.format(
      '@@ -%d,%d +%d,%d @@',
      h.removed.start,
      h.removed.count,
      h.added.start,
      h.added.count
    ),
  }
  for _, line in ipairs(lines.removed) do
    text[#text + 1] = '-' .. line
  end
  for _, line in ipairs(lines.added) do
    text[#text + 1] = '+' .. line
  end
  return text
end

--- The lines of `base_lines` a hunk removes that the buffer no longer holds
--- anywhere.
---
--- A `change` pairs its removed lines with its added ones (that is what the word
--- diff compares), so only the surplus is hidden; a `delete` / `topdelete`
--- removes every line it names.
---@param h vcssign.Hunk
---@param base_lines string[]
---@param buf_lines string[]
---@return string[] hidden
local function hidden_lines(h, base_lines, buf_lines)
  local removed = hunk.lines_of(h, base_lines, buf_lines).removed
  local paired = 0
  if h.type == 'change' or h.type == 'changedelete' then
    paired = math.min(h.removed.count, h.added.count)
  end
  local hidden = {}
  for i = paired + 1, #removed do
    hidden[#hidden + 1] = removed[i]
  end
  return hidden
end

--- Where the removed lines of a hunk belong in the buffer: the 1-based line the
--- virtual lines hang on, and whether they go above it.
---
--- `delete` and `change` put their sign on the line the block follows, so their
--- lines are shown below it; `topdelete` names the top of the file, where
--- "above" is outside the buffer, so its lines are shown above line 1.
---@param h vcssign.Hunk
---@return integer anchor, boolean above
local function anchor_of(h)
  if h.type == 'topdelete' then
    return 1, true
  end
  if h.type == 'delete' then
    return signs.sign_line(h), false
  end
  return h.added.start + h.added.count - 1, false
end

--- Show the lines `hunks` remove from the file as virtual lines at their place
--- (`config.deleted_preview`).
---@param bufnr integer
---@param hunks vcssign.Hunk[]
---@param base_lines string[]?
---@param buf_lines string[]
---@return integer placed  how many hunk previews were drawn
function M.render_deleted(bufnr, hunks, base_lines, buf_lines)
  local ns = M.namespace()
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not config.get().deleted_preview or base_lines == nil then
    return 0
  end
  local line_count = api.nvim_buf_line_count(bufnr)
  local placed = 0
  for _, h in ipairs(hunks or {}) do
    local hidden = hidden_lines(h, base_lines, buf_lines)
    local anchor, above = anchor_of(h)
    if #hidden > 0 and anchor and anchor >= 1 and anchor <= line_count then
      local virt_lines = {}
      for _, line in ipairs(hidden) do
        virt_lines[#virt_lines + 1] = { { line, VIRT_GROUP } }
      end
      api.nvim_buf_set_extmark(bufnr, ns, anchor - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = above,
      })
      placed = placed + 1
    end
  end
  return placed
end

--- The preview window that is currently open, if any.
---@type { win: integer, src: integer, lnum: integer }?
local float = nil

--- The size of the preview window: the hunk's own size, capped so it never
--- takes over the editor.
---@param text string[]
---@return integer width, integer height
local function float_size(text)
  local longest = 0
  for _, line in ipairs(text) do
    longest = math.max(longest, vim.fn.strdisplaywidth(line))
  end
  local max_width = math.max(20, math.floor(vim.o.columns * 0.8))
  local max_height = math.max(3, math.floor(vim.o.lines * 0.8))
  return math.min(longest + 2, max_width), math.min(#text, max_height)
end

--- Close the hunk preview, wherever it is open.
---
--- The preview buffer is `bufhidden=wipe`, so closing the window is all it takes
--- to get rid of both.
function M.close()
  if not float then
    return
  end
  local win = float.win
  float = nil
  if api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

--- Whether the preview is open for this buffer (and, when given, this line).
---@param bufnr integer
---@param lnum? integer
---@return boolean
function M.is_open(bufnr, lnum)
  return float ~= nil
    and float.src == bufnr
    and (lnum == nil or float.lnum == lnum)
    and api.nvim_win_is_valid(float.win)
end

--- Open `text` in a floating window, replacing whatever float is already open.
---
--- The window is a glance, not something to manage: it closes as soon as the
--- cursor leaves the line it describes, or the buffer loses the focus.  It is
--- deliberately not focusable (`enter = false`), so the cursor stays in the
--- file being read.
---@param bufnr integer  the buffer the float describes
---@param lnum integer   the line it describes, for `is_open` and the title
---@param text string[]
---@param opts? { filetype?: string, title?: string }
---@return integer win
function M.open(bufnr, lnum, text, opts)
  opts = opts or {}
  M.close()
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, text)
  if opts.filetype then
    api.nvim_set_option_value('filetype', opts.filetype, { buf = buf })
  end
  api.nvim_set_option_value('bufhidden', 'wipe', { buf = buf })
  api.nvim_set_option_value('modifiable', false, { buf = buf })
  local width, height = float_size(text)
  local win = api.nvim_open_win(buf, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = 'minimal',
    border = 'single',
    title = opts.title or '',
  })
  float = { win = win, src = bufnr, lnum = lnum }
  api.nvim_create_autocmd({ 'CursorMoved', 'BufLeave' }, {
    buffer = bufnr,
    once = true,
    callback = function()
      M.close()
    end,
  })
  return win
end

--- Show one hunk in a floating window, or close it when that hunk is already
--- the one on show (the `preview_hunk` action is a toggle).
---@param bufnr integer  the buffer the hunk belongs to
---@param h vcssign.Hunk
---@param lnum integer  the line the sign sits on, for the title and the toggle
---@param base_lines string[]
---@param buf_lines string[]
---@return boolean shown
function M.toggle_hunk(bufnr, h, lnum, base_lines, buf_lines)
  if M.is_open(bufnr, lnum) then
    M.close()
    return false
  end
  M.open(bufnr, lnum, M.hunk_text(h, base_lines, buf_lines), {
    filetype = 'diff',
    title = string.format(' %s:%d ', vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ':t'), lnum),
  })
  return true
end

--- Clear both previews of one buffer.
---@param bufnr integer
function M.clear(bufnr)
  api.nvim_buf_clear_namespace(bufnr, M.namespace(), 0, -1)
  if float and float.src == bufnr then
    M.close()
  end
end

return M
