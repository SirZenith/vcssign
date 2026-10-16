--- Line-level hunk model.
---
--- A hunk is the pure-data half of the sign layer: it knows *where* a
--- difference is and enough to render a sign or rebuild a patch, and nothing
--- about buffers, signs, or VCS commands.  `vim.text.diff` produces hunks (as
--- `indices`), and the renderer consumes them; keeping the model free of both
--- makes it testable without nvim's UI or a repository.
---
--- Ported from gitsigns.nvim (`lua/gitsigns/hunks.lua`), which is MIT
--- licensed:
---
---   MIT License
---   Copyright (c) 2020 Lewis Russell
---   https://github.com/lewis6991/gitsigns.nvim
---
--- See loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md for the design (D40).
---
--- `vim.text.diff(..., { result_type = 'indices' })` returns one group of four
--- numbers per hunk, in *1-based* line numbers:
---
---   { start_a, count_a, start_b, count_b }
---
--- where `count_a`/`count_b` are the number of lines removed/added.  A pure
--- insertion therefore has `count_a == 0` and a `start_a` that may be 0 ("before
--- the first line"); a pure deletion has `count_b == 0`.  (Verified by hand on
--- nvim 0.12.4; see loop/archive/testing/2026-10-16T17-33-54-testing-infra-and-toolchain.md.)

--- A node of a hunk: a 1-based start line and a line count.  `start` is only
--- meaningful when `count > 0`, and for an insertion `removed.start` is the
--- line the new text follows (0 = before the first line).  `lines` is filled in
--- lazily (`lines_of`) and only needed when two hunks must be compared by
--- content, as `filter_common` does.
---@class vcssign.Hunk.Node
---@field start integer
---@field count integer
---@field lines? string[]

--- The difference kinds the sign layer knows about.  `from_indices` only ever
--- emits add/change/delete/topdelete: `changedelete` (a change that removes
--- more lines than it adds) is a *rendering* choice and `untracked` comes from
--- the VCS, not from a diff (D40).
---@alias vcssign.Hunk.Type
---| 'add'
---| 'change'
---| 'delete'
---| 'topdelete'
---| 'changedelete'
---| 'untracked'

---@class vcssign.Hunk
---@field added vcssign.Hunk.Node
---@field removed vcssign.Hunk.Node
---@field type vcssign.Hunk.Type
---@field lines? string[]

local M = {}

--- Turn `vim.text.diff`'s `indices` output into hunks.
---@param indices integer[][] list of `{ start_a, count_a, start_b, count_b }`
---@return vcssign.Hunk[]
function M.from_indices(indices)
  local hunks = {}
  for _, group in ipairs(indices or {}) do
    local start_a, count_a, start_b, count_b = group[1], group[2], group[3], group[4]
    local hunk = {
      added = { start = start_b, count = count_b },
      removed = { start = start_a, count = count_a },
    }
    if count_a == 0 then
      hunk.type = 'add'
    elseif count_b == 0 then
      -- Removing the very first line is worth calling out: the sign goes in the
      -- buffer's first `virt_lines`/sign slot rather than on a line.
      hunk.type = start_a == 1 and 'topdelete' or 'delete'
    else
      hunk.type = 'change'
    end
    hunks[#hunks + 1] = hunk
  end
  return hunks
end

--- Do two hunks introduce the same text at the same place?  Only the "new"
--- side is compared, exactly as gitsigns does.
---@param a vcssign.Hunk
---@param b vcssign.Hunk
---@return boolean
local function same_added(a, b)
  if a.added.start ~= b.added.start or a.added.count ~= b.added.count then
    return false
  end
  for i = 1, a.added.count do
    -- Both sides may be unset; unset lines compare equal, exactly as an empty
    -- `lines` table does in gitsigns.
    if (a.added.lines or {})[i] ~= (b.added.lines or {})[i] then
      return false
    end
  end
  return true
end

--- Remove from `a` the hunks that `b` covers, comparing only the new side.
---
--- Use case: git has two sign domains — staged (`index` vs `HEAD`) and unstaged
--- (`worktree` vs `index`).  Unstaged hunks that the index already contains are
--- not really unstaged; filtering the unstaged list through the staged list
--- yields the "still to stage" signs.
---@param a vcssign.Hunk[]?
---@param b vcssign.Hunk[]?
---@return vcssign.Hunk[]?
function M.filter_common(a, b)
  if not a and not b then
    return nil
  end
  a, b = a or {}, b or {}

  local a_i, b_i = 1, 1
  local ret = {}

  -- +1 so the loop body can flush the remainder of `a` after `b` runs out.
  for _ = 1, math.max(#a, #b) + 1 do
    local a_h, b_h = a[a_i], b[b_i]

    if not a_h then
      break
    end
    if not b_h then
      -- b ended first: everything left in a is unfiltered.
      for i = a_i, #a do
        ret[#ret + 1] = a[i]
      end
      break
    end

    if a_h.added.start > b_h.added.start then
      b_i = b_i + 1
    elseif a_h.added.start < b_h.added.start then
      ret[#ret + 1] = a_h
      a_i = a_i + 1
    else
      if not same_added(a_h, b_h) then
        ret[#ret + 1] = a_h
      end
      a_i = a_i + 1
      b_i = b_i + 1
    end
  end

  return ret
end

--- Sort hunks by where they land in the new buffer, then by where they came
--- from.  Returns a new list; the input is left alone.
---
--- `table.sort` is not stable, so equal keys fall back to the input position —
--- two hunks can legitimately share `added.start` (a zero-width insertion and a
--- deletion ending there), and their relative order must not wobble.
---@param hunks vcssign.Hunk[]
---@return vcssign.Hunk[]
function M.sort(hunks)
  local n = #hunks
  local order = {}
  for i = 1, n do
    order[i] = i
  end
  table.sort(order, function(x, y)
    local ax, ay = hunks[x], hunks[y]
    if ax.added.start ~= ay.added.start then
      return ax.added.start < ay.added.start
    end
    if ax.removed.start ~= ay.removed.start then
      return ax.removed.start < ay.removed.start
    end
    return x < y
  end)

  local sorted = {}
  for i = 1, n do
    sorted[i] = hunks[order[i]]
  end
  return sorted
end

--- The concrete lines a hunk removes from `base_lines` and adds from
--- `buf_lines`.  Both are 1-based line lists (see `vcssign.diff.split` /
--- `nvim_buf_get_lines`).
---@param hunk vcssign.Hunk
---@param base_lines string[]
---@param buf_lines string[]
---@return { removed: string[], added: string[] }
function M.lines_of(hunk, base_lines, buf_lines)
  local function slice(lines, node)
    if node.count == 0 then
      return {}
    end
    local out = {}
    for i = 0, node.count - 1 do
      out[i + 1] = lines[node.start + i]
    end
    return out
  end
  return {
    removed = slice(base_lines, hunk.removed),
    added = slice(buf_lines, hunk.added),
  }
end

--- `start` or `start,count`, following git's habit of dropping a count of 1.
---@param start integer
---@param count integer
---@return string
local function range(start, count)
  if count == 1 then
    return tostring(start)
  end
  return string.format('%d,%d', start, count)
end

--- Build a *zero-context* unified diff for one hunk.
---
--- Zero context keeps the patch minimal, which is what the staged-apply path
--- wants (`git apply --cached --unidiff-zero -` reads it from stdin, D41).  The
--- result always ends with a newline: a patch without a final newline is
--- rejected with `error: corrupt patch at <stdin>:N` (measured).
---
--- `opts.base_no_nl_at_eof` / `opts.buf_no_nl_at_eof` emit git's
--- `\ No newline at end of file` marker.  The hunk model does not carry that
--- bit, so the caller must have kept it while normalising the text; callers
--- that do not care can omit `opts`.
---
--- `opts.headers = false` suppresses the three file headers (`diff --git`,
--- `---`, `+++`) and leaves only the `@@` block: a whole-file diff announces the
--- file once and then lists several hunks, so `vcssign.revdiff` writes the
--- headers itself and builds every body with `headers = false`.
---
--- @param hunk vcssign.Hunk
--- @param base_lines string[]
--- @param buf_lines string[]
--- @param rel string repository-relative path (backslashes are normalised)
--- @param opts? { base_no_nl_at_eof?: boolean, buf_no_nl_at_eof?: boolean, headers?: boolean }
--- @return string
function M.build_patch(hunk, base_lines, buf_lines, rel, opts)
  opts = opts or {}
  rel = rel:gsub('\\', '/')

  local lines = M.lines_of(hunk, base_lines, buf_lines)
  local out = {}
  if opts.headers ~= false then
    out[#out + 1] = string.format('diff --git a/%s b/%s', rel, rel)
    out[#out + 1] = string.format('--- a/%s', rel)
    out[#out + 1] = string.format('+++ b/%s', rel)
  end
  out[#out + 1] = string.format(
    '@@ -%s +%s @@',
    range(hunk.removed.start, hunk.removed.count),
    range(hunk.added.start, hunk.added.count)
  )

  for _, line in ipairs(lines.removed) do
    out[#out + 1] = '-' .. line
  end
  if opts.base_no_nl_at_eof and #lines.removed > 0 then
    out[#out + 1] = '\\ No newline at end of file'
  end

  for _, line in ipairs(lines.added) do
    out[#out + 1] = '+' .. line
  end
  if opts.buf_no_nl_at_eof and #lines.added > 0 then
    out[#out + 1] = '\\ No newline at end of file'
  end

  return table.concat(out, '\n') .. '\n'
end

return M
