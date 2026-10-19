--- The diff view: the scratch window `:Vcssign diff` and `diffthis [rev]` show
--- their text in, plus the text of an arbitrary-revision diff
--- (impl/knowledge/signs/ §3, Step 11).
---
--- Two things share the module because they are the same view:
---
---  * the window is reused across presses (pressing the key twice focuses the
---    diff instead of stacking another split, and the split direction comes
---    from `diff.mode` in one place), and
---  * `M.text` builds the comparison against a *given* revision.  No adapter can
---    print that for us — `system.diff` only knows the configured baseline
---    (D39/D42) — so it is built from `show(root, rev, rel)` and the buffer's
---    own lines, in the shape `git diff` prints.
local api = vim.api
local config = require('vcssign.config')
local diff = require('vcssign.diff')
local hunk = require('vcssign.hunk')
local log = require('vcssign.log')

local M = {}

---@param fmt string
---@param ... any
local function fail(fmt, ...)
  log.notify_error(select('#', ...) == 0 and fmt or string.format(fmt, ...))
end

--- The buffer a file's diff is shown in, reused across presses.
---@param t vcssign.Target
---@return integer
function M.buffer(t)
  local name = 'vcssign://' .. t.repo.system.name .. '/' .. t.repo.root .. '/' .. t.rel_path
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_get_name(bufnr) == name then
      if api.nvim_buf_is_loaded(bufnr) then
        return bufnr
      end
      -- Left over from a `:bunload`: start over rather than write into a
      -- buffer that would have to be loaded first.
      api.nvim_buf_delete(bufnr, { force = true })
      break
    end
  end
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  -- The diff is a view, not a document: closing its window should end it.
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].filetype = 'diff'
  return bufnr
end

--- Show `text` as a unified diff in a new window.
---@param t vcssign.Target
---@param text string
function M.show(t, text)
  local bufnr = M.buffer(t)
  vim.bo[bufnr].modifiable = true
  -- `trimempty` drops the empty line a trailing newline would add (a diff
  -- ends with one); empty *context* lines inside the diff are kept.
  local lines = vim.split(text, '\n', { plain = true, trimempty = true })
  local ok, err = pcall(api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  if api.nvim_buf_is_valid(bufnr) then
    -- Read-only: an accidental edit would make the buffer lie about the diff
    -- it is supposed to be showing.
    vim.bo[bufnr].modifiable = false
  end
  if not ok then
    error(err, 0)
  end

  -- The window may already be showing this diff (the user pressed the key
  -- twice, or came back to the file): focus it instead of stacking another
  -- split.
  local existing = vim.fn.bufwinid(bufnr)
  if existing ~= -1 then
    api.nvim_set_current_win(existing)
    return
  end

  -- A sensible default size, and one place that knows which way the split
  -- goes, so the two modes cannot drift apart.
  local opts = config.get().diff.mode == 'split'
      and { split = 'below', height = math.max(10, math.floor(vim.o.lines / 2)) }
    or { split = 'right', width = math.max(40, math.floor(vim.o.columns / 2)) }
  -- Opening a window can fail (no room), and that must arrive as a message
  -- rather than as an error inside a callback.
  local opened, win = pcall(api.nvim_open_win, bufnr, true, opts)
  if not opened then
    return fail(tostring(win))
  end
  vim.wo[win].wrap = false
  vim.wo[win].foldenable = false
  api.nvim_win_set_cursor(win, { 1, 0 })
end

--- The text of a diff between a revision and the buffer's lines.
---
--- The body of each hunk comes from `hunk.build_patch` — the same writer the
--- hunk actions use — with its per-hunk file headers suppressed, because a
--- whole-file diff announces `a/<rel>` and `b/<rel>` once, above every hunk,
--- the way `git diff` does.
---@param rel string
---@param base_text string
---@param buf_lines string[]
---@return string
function M.text(rel, base_text, buf_lines)
  local base = diff.normalize(base_text)
  local hunks = diff.run(base, diff.join(buf_lines))
  if #hunks == 0 then
    return ''
  end
  rel = rel:gsub('\\', '/')
  local base_lines = diff.split(base)
  local out = {
    string.format('diff --git a/%s b/%s\n', rel, rel),
    string.format('--- a/%s\n', rel),
    string.format('+++ b/%s\n', rel),
  }
  for _, h in ipairs(hunks) do
    out[#out + 1] = hunk.build_patch(h, base_lines, buf_lines, rel, { headers = false })
  end
  return table.concat(out, '')
end

return M
