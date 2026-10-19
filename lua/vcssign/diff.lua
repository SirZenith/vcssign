--- The built-in diff driver.
---
--- Neovim ships a diff engine (`vim.text.diff`); vcssign uses it instead of
--- shelling out to `git diff` (D39).  That keeps hunk computation on the main
--- loop with no process to babysit, and it is fast enough to run per
--- keystroke (myers on 20k lines is single-digit milliseconds — measured).
---
--- The one trap is the newline convention.  `nvim_buf_get_lines()` joined with
--- `\n` never has a trailing newline, while `git show`/`svn cat` always do.  If
--- the two sides disagree, the diff invents a change on the last line, so both
--- sides are normalised to "no trailing newline" here and nowhere else.
---
--- See loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md (D39/D43).
local config = require('vcssign.config')
local hunk = require('vcssign.hunk')

local M = {}

--- Join buffer lines into diff text: no trailing newline after the last line.
---@param lines string[]
---@return string
function M.join(lines)
  return table.concat(lines, '\n')
end

--- Strip *exactly one* trailing newline, and only if there is one.
---@param text string
---@return string
function M.normalize(text)
  if text:sub(-1) == '\n' then
    return text:sub(1, -2)
  end
  return text
end

--- Split text into 1-based lines, normalising first.
---
--- An empty file yields `{ '' }` (one empty line), matching what
--- `nvim_buf_get_lines()` reports for an empty buffer; a file ending in `\n`
--- does not gain a phantom last line.
---@param text string
---@return string[]
function M.split(text)
  return vim.split(M.normalize(text), '\n', { plain = true })
end

--- Prefer an explicit option over the configured default; `false` counts.
---@param override any
---@param fallback any
---@return any
local function pick(override, fallback)
  if override ~= nil then
    return override
  end
  return fallback
end

---@class vcssign.DiffOpts
---@field algorithm? string
---@field ignore_cr_at_eol? boolean
---@field linematch? boolean|integer
---@field indent_heuristic? boolean

--- Diff two texts and return sorted hunks.
---
--- Both arguments must use the same newline convention; build the buffer side
--- with `M.join(buf_lines)` and the baseline side with `M.normalize(stdout)`.
---
--- Note on `linematch`: `true` means "run linematch on every hunk, however
--- large", and linematch is quadratic in hunk size — an all-changed 20k-line
--- buffer effectively hangs.  `config.diff.linematch` therefore defaults to
--- `false` (see the measurement in `lua/vcssign/config.lua`), so the default
--- path never runs it; a caller that turns it on should pass a bounded integer
--- ("only hunks up to this many lines") rather than `true`.  Kept as a caller
--- concern until the config surface is revised.
---@param a_text string
---@param b_text string
---@param opts? vcssign.DiffOpts
---@return vcssign.Hunk[]
function M.run(a_text, b_text, opts)
  opts = opts or {}
  local cfg = config.get().diff or {}
  local indices = vim.text.diff(a_text, b_text, {
    result_type = 'indices',
    algorithm = pick(opts.algorithm, cfg.algorithm or 'myers'),
    ignore_cr_at_eol = pick(opts.ignore_cr_at_eol, cfg.ignore_cr_at_eol),
    linematch = pick(opts.linematch, cfg.linematch),
    indent_heuristic = pick(opts.indent_heuristic, cfg.indent_heuristic),
  })
  return hunk.sort(hunk.from_indices(indices))
end

return M
