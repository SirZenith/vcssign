--- What changed *inside* a modified line (`config.word_diff`, signs §4 / §6 Step 10).
---
--- A `change` hunk replaces whole lines, and the buffer already tints them with
--- the `Ln` highlight group; the word diff narrows that down to the tokens that
--- actually differ.  That is the difference between "this line changed" and
--- "here is what changed".
---
--- The tokenisation and the range computation are deliberately free of buffers:
--- `test/worddiff_spec.lua` checks them with two strings, no repository and no
--- VCS binary.
local api = vim.api
local config = require('vcssign.config')

local M = {}

local NS = 'vcssign_worddiff'

--- Just above `vim.hl.priorities.treesitter` (100), so the inline highlight is
--- visible in highlighted code instead of being painted over; semantic tokens
--- (125) still win.  A word diff is a hint about *this* change, not a
--- replacement for syntax highlighting.
local PRIORITY = ((vim.hl or {}).priorities or {}).treesitter or 100
PRIORITY = PRIORITY + 1

--- The group of the inline ranges.  `DiffText` is the group every colorscheme
--- already defines as "the text that changed within a diff line".
function M.define_highlights()
  api.nvim_set_hl(0, 'VcssignWordDiff', { link = 'DiffText', default = true })
end

---@type integer?
M._ns = nil

--- The namespace the inline ranges live in (`vcssign_worddiff`, signs §4).
---@return integer
function M.namespace()
  if not M._ns then
    M._ns = api.nvim_create_namespace(NS)
  end
  return M._ns
end

--- Split one line into the tokens the diff runs over: runs of keyword
--- characters, runs of blanks, and every other character on its own.
---
--- Character granularity for punctuation and for non-ASCII text is what a
--- reader wants ("they changed `,` to `;`", "they changed 一 to 二").  Byte
--- granularity would cut a multi-byte character in half and would hand CJK text
--- a different diff than ASCII text.
---@param line string
---@return string[] tokens
local function tokenize(line)
  local tokens = {}
  local i, n = 1, #line
  while i <= n do
    local c = line:sub(i, i)
    local j = i + 1
    if c:match('[%w_]') then
      while j <= n and line:sub(j, j):match('[%w_]') do
        j = j + 1
      end
    elseif c:match('%s') then
      while j <= n and line:sub(j, j):match('%s') do
        j = j + 1
      end
    else
      -- One UTF-8 character: the leading byte says how long it is.
      local first = line:byte(i)
      j = i + (first < 0x80 and 1 or (first < 0xE0 and 2 or (first < 0xF0 and 3 or 4)))
      if j > n + 1 then
        j = n + 1
      end
    end
    tokens[#tokens + 1] = line:sub(i, j - 1)
    i = j
  end
  return tokens
end

--- The byte ranges of `new` that differ from `old`.
---
--- Returned as 0-based `{ start_col, end_col }` pairs — the half-open
--- convention `nvim_buf_set_extmark` uses for `end_col`.
---@param old string
---@param new string
---@return integer[][] ranges
function M.ranges(old, new)
  if old == new then
    return {}
  end
  local new_tokens = tokenize(new)
  if #new_tokens == 0 then
    return {}
  end
  local old_tokens = tokenize(old)
  if #old_tokens == 0 then
    -- Nothing to compare with: the whole line is new text.
    return { { 0, #new } }
  end
  -- `vim.text.diff` takes texts and splits them on "\n", so the token
  -- sequences travel as "\n"-joined strings.  A token never contains a
  -- newline (it comes from one line), which is what makes the mapping back to
  -- byte columns exact.
  local indices = vim.text.diff(table.concat(old_tokens, '\n'), table.concat(new_tokens, '\n'), {
    result_type = 'indices',
    -- The tokens are already the granularity we want; a heuristic that shuffles
    -- them around would only move the ranges.
    indent_heuristic = false,
  })

  -- Byte offset of the first byte of each token in `new`.
  local starts = {}
  local offset = 0
  for i, token in ipairs(new_tokens) do
    starts[i] = offset
    offset = offset + #token
  end

  local ranges = {}
  for _, idx in ipairs(indices) do
    local start_a, count_a, start_b, count_b = idx[1], idx[2], idx[3], idx[4]
    -- `count_b == 0` is a pure removal: nothing in `new` to highlight.
    if count_b > 0 then
      -- xdiff may report a hunk whose two sides share a prefix or a suffix —
      -- deleting the tail of `a = 1 2` comes back as "replace `1`, ` `, `2`
      -- with `1`", for instance.  Trimming both ends leaves the text that is
      -- genuinely new; if nothing is left, the line lost text and has no new
      -- text to paint (which is what a pure removal looks like).
      local first_a, last_a = start_a, start_a + count_a - 1
      local first_b, last_b = start_b, start_b + count_b - 1
      while
        first_b <= last_b
        and first_a <= last_a
        and new_tokens[first_b] == old_tokens[first_a]
      do
        first_a, first_b = first_a + 1, first_b + 1
      end
      while last_b >= first_b and last_a >= first_a and new_tokens[last_b] == old_tokens[last_a] do
        last_a, last_b = last_a - 1, last_b - 1
      end
      if first_b <= last_b then
        ranges[#ranges + 1] = { starts[first_b], starts[last_b] + #new_tokens[last_b] }
      end
    end
  end
  return ranges
end

--- Clear the inline ranges of one buffer.
---@param bufnr integer
function M.clear(bufnr)
  api.nvim_buf_clear_namespace(bufnr, M.namespace(), 0, -1)
end

--- Highlight what changed inside every modified line of `hunks`.
---
--- A `change` hunk pairs its removed lines with its added lines one by one
--- (n-th removed with n-th added) and compares those; a pair with no
--- counterpart on one side (a line replaced by three, three by one) leaves the
--- surplus alone, which is exactly what the deleted-line preview shows instead.
--- `add`/`delete`/`untracked` hunks get no inline ranges: there is nothing to
--- compare, and the sign (or the preview) already carries the whole block.
---@param bufnr integer
---@param hunks vcssign.Hunk[]
---@param base_lines string[]?  nil when there is no baseline to read
---@param buf_lines string[]
---@return integer placed  how many ranges were highlighted
function M.render(bufnr, hunks, base_lines, buf_lines)
  local ns = M.namespace()
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  if not config.get().word_diff or base_lines == nil then
    return 0
  end
  local placed = 0
  for _, h in ipairs(hunks or {}) do
    if h.type == 'change' or h.type == 'changedelete' then
      for i = 1, math.min(h.removed.count, h.added.count) do
        local old = base_lines[h.removed.start + i - 1]
        local new = buf_lines[h.added.start + i - 1]
        if old and new then
          for _, range in ipairs(M.ranges(old, new)) do
            api.nvim_buf_set_extmark(bufnr, ns, h.added.start + i - 2, range[1], {
              end_col = range[2],
              hl_group = 'VcssignWordDiff',
              priority = PRIORITY,
            })
            placed = placed + 1
          end
        end
      end
    end
  end
  return placed
end

return M
