--- Renderer specs: ordering, grouping, labels, signs, highlights.
---
--- Pure — no repository, no VCS binary.  `build`/`for_repo` take entries (or a
--- three-field stand-in for a repo) so every rule can be pinned down without a
--- window; only the sign/highlight cases need a real buffer to draw into.
--- See impl/init/03-sidebar-ui.md §3 and §6.
local renderer = require('vcssign.sidebar.renderer')
local status_type = require('vcssign.status_type')

---@param rel string
---@param status vcssign.FileStatus
---@return vcssign.StatusEntry
local function entry(rel, status)
  return { path = 'D:/repo/' .. rel, rel_path = rel, status = status }
end

--- The parts of `vcssign.Repo` the renderer touches, without a repository.
---@param entries vcssign.StatusEntry[]
---@param opts? { has_loaded?: boolean, last_error?: string, has_index?: boolean }
local function fake_repo(entries, opts)
  opts = opts or {}
  return {
    system = {
      name = opts.has_index == false and 'svn' or 'git',
      capabilities = { stage = opts.has_index ~= false },
    },
    has_loaded = opts.has_loaded ~= false,
    last_error = opts.last_error,
    entries = function()
      return entries
    end,
  }
end

--- Texts of the built rows.
---@param items vcssign.RenderItem[]
---@return string[]
local function texts(items)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = item.text
  end
  return out
end

--- 1-based row of the first entry whose `rel_path` is `rel`.
---@param items vcssign.RenderItem[]
---@param rel string
---@return integer
local function row_of(items, rel)
  for i, item in ipairs(items) do
    if item.entry and item.entry.rel_path == rel then
      return i
    end
  end
  error('no row for ' .. rel)
end

--- `rel_path` of every entry row (group headers skipped), in row order.
---@param items vcssign.RenderItem[]
---@return string[]
local function rel_paths(items)
  local out = {}
  for _, item in ipairs(items) do
    if item.entry then
      out[#out + 1] = item.entry.rel_path
    end
  end
  return out
end

--- Signs drawn on `line` (0-based), highest priority first.
---@param bufnr integer
---@param line integer
---@return table[] extmark details with `sign_text`
local function signs_at(bufnr, line)
  local found = {}
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(bufnr, renderer.ns, 0, -1, { details = true }))
  do
    if mark[2] == line and mark[4].sign_text then
      found[#found + 1] = mark[4]
    end
  end
  table.sort(found, function(a, b)
    return (a.priority or 0) > (b.priority or 0)
  end)
  return found
end

--- A scratch buffer, thrown away by the case that made it.
---@return integer
local function scratch_buffer()
  return vim.api.nvim_create_buf(false, true)
end

--- The line highlight `draw` put on `line` (0-based), or nil.
---@param bufnr integer
---@param line integer
---@return string?
local function line_hl(bufnr, line)
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(bufnr, renderer.ns, 0, -1, { details = true }))
  do
    if mark[2] == line and mark[4].line_hl_group then
      return mark[4].line_hl_group
    end
  end
  return nil
end

return {
  {
    name = 'rows are ordered by severity, then by path',
    fn = function()
      local items = renderer.build({
        entry('m.txt', { worktree = 'modified' }),
        entry('u.txt', { worktree = 'untracked' }),
        entry('z.txt', { index = 'conflicted', worktree = 'conflicted' }),
        entry('a.txt', { worktree = 'modified' }),
        entry('r.txt', { index = 'renamed', worktree = 'renamed', orig_path = 'old.txt' }),
      }, { group_by = 'none' })
      eq(
        rel_paths(items),
        { 'z.txt', 'a.txt', 'm.txt', 'r.txt', 'u.txt' },
        'conflicted first; then modified by path; then renamed; then untracked'
      )
    end,
  },
  {
    name = 'the severity order is the one the plan documents',
    fn = function()
      -- Every status the enum has, one row each, so a change to
      -- `status_type.default_sign_priority` has to face this list (and 03 §3.1).
      local names = {}
      for _, status in pairs(status_type.StatusType) do
        names[#names + 1] = status
      end
      table.sort(names)
      local entries = {}
      for i, status in ipairs(names) do
        entries[i] = entry(status, { worktree = status })
      end
      eq(rel_paths(renderer.build(entries, { group_by = 'none' })), {
        'conflicted',
        'missing',
        -- equals at 50 / 40 are broken by path
        'modified',
        'replaced',
        'typechange',
        'deleted',
        'renamed',
        'added',
        'untracked',
        'obstructed',
        'switched',
        'external',
        'ignored',
      })
    end,
  },
  {
    name = 'the status cache of the repository is never reordered in place',
    fn = function()
      local entries = {
        entry('z.txt', { worktree = 'modified' }),
        entry('a.txt', { index = 'conflicted', worktree = 'conflicted' }),
      }
      renderer.build(entries, { group_by = 'none' })
      eq(entries[1].rel_path, 'z.txt', 'build must copy before sorting')
    end,
  },
  {
    name = 'long paths keep their tail and lose their head',
    fn = function()
      local deep = 'src/very/deeply/nested/directory/tree/with/a/file.txt'
      local items = renderer.build(
        { entry(deep, { worktree = 'modified' }) },
        { width = 30, group_by = 'none' }
      )
      local text = items[1].text
      ok(
        vim.fn.strchars(text) <= 30 - renderer.sign_cells - 1,
        'row text fits the budget, got ' .. text
      )
      eq(vim.fn.strcharpart(text, 0, 1), '…', 'the head is cut')
      ok(text:find('file.txt', 1, true), 'the file name survives, got ' .. text)
      eq(text:sub(-#'file.txt'), 'file.txt', 'the tail is kept intact')
    end,
  },
  {
    name = 'a rename row shows where the file came from',
    fn = function()
      local items = renderer.build(
        { entry('new/name.txt', { index = 'renamed', orig_path = 'old/name.txt' }) },
        { group_by = 'none' }
      )
      eq(items[1].text, 'new/name.txt (from old/name.txt)')
    end,
  },
  {
    name = 'git rows split into Staged, Unstaged and Untracked',
    fn = function()
      local items = renderer.build({
        entry('untracked.txt', { worktree = 'untracked' }),
        entry('unstaged.txt', { worktree = 'modified' }),
        entry('staged.txt', { index = 'added' }),
        entry('both.txt', { index = 'added', worktree = 'modified' }),
      }, { group_by = 'status', has_index = true })
      eq(texts(items), {
        '── Staged (2) ──',
        'both.txt',
        'staged.txt',
        '── Unstaged (1) ──',
        'unstaged.txt',
        '── Untracked (1) ──',
        'untracked.txt',
      })
      eq(items[1].kind, 'header')
      eq(items[1].group, 'Staged')
      eq(items[2].kind, 'entry')
      eq(items[2].group, 'Staged')
      -- A file staged *and* edited again counts as staged: the index is where
      -- it changed.  Its second sign still shows the follow-up edit.
      eq(items[2].entry.rel_path, 'both.txt')
    end,
  },
  {
    name = 'a system without an index renders one flat list',
    fn = function()
      local items = renderer.build({
        entry('a.txt', { worktree = 'modified' }),
        entry('b.txt', { worktree = 'missing' }),
      }, { group_by = 'status', has_index = false })
      eq(texts(items), { 'b.txt', 'a.txt' }, 'no group headers for svn')
      eq(items[1].kind, 'entry')
    end,
  },
  {
    name = 'group_by = none renders one flat list even for git',
    fn = function()
      local items = renderer.build({
        entry('staged.txt', { index = 'added' }),
        entry('plain.txt', { worktree = 'modified' }),
      }, { group_by = 'none', has_index = true })
      eq(texts(items), { 'plain.txt', 'staged.txt' }, 'ordered by severity across the whole list')
    end,
  },
  {
    name = 'a file in both domains gets one sign per domain, porcelain order',
    fn = function()
      local bufnr = scratch_buffer()
      renderer.draw(
        bufnr,
        renderer.build(
          { entry('both.txt', { index = 'added', worktree = 'modified' }) },
          { group_by = 'none' }
        )
      )
      local signs = signs_at(bufnr, 0)
      eq(#signs, 2, 'two signs')
      -- Higher priority sits leftmost (measured with screenstring), so the index
      -- sign leads — exactly like `git status --short` printing X before Y.
      eq(signs[1].sign_text, ' A', 'index sign leads')
      eq(signs[1].sign_hl_group, 'VcssignSignAdded')
      eq(signs[1].priority, status_type.sign_priority('added') + renderer.upstream_offset)
      eq(signs[2].sign_text, ' M', 'worktree sign follows')
      eq(signs[2].sign_hl_group, 'VcssignSignModified')
      eq(signs[2].priority, status_type.sign_priority('modified'))
      ok(
        signs[1].priority > signs[2].priority + status_type.sign_priority('conflicted'),
        'the upstream offset clears the worst local priority'
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
  },
  {
    name = 'a single-domain row gets exactly one sign',
    fn = function()
      local bufnr = scratch_buffer()
      local items = renderer.build({
        entry('staged.txt', { index = 'added' }),
        entry('edited.txt', { worktree = 'modified' }),
        entry('new.txt', { worktree = 'untracked' }),
      }, { group_by = 'none' })
      renderer.draw(bufnr, items)
      for row = 1, #items do
        eq(
          #signs_at(bufnr, row - 1),
          1,
          'one sign on row ' .. row .. ' (' .. items[row].text .. ')'
        )
      end
      eq(signs_at(bufnr, row_of(items, 'edited.txt') - 1)[1].sign_text, ' M')
      eq(signs_at(bufnr, row_of(items, 'staged.txt') - 1)[1].sign_text, ' A')
      eq(signs_at(bufnr, row_of(items, 'new.txt') - 1)[1].sign_text, ' U')
      -- The draw must hand the buffer's editability back the way it found it.
      eq(vim.bo[bufnr].modifiable, true, 'a scratch buffer stays modifiable')
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
  },
  {
    name = 'every status the enum can produce has a highlight group',
    fn = function()
      for _, status in pairs(status_type.StatusType) do
        ok(renderer.highlights[status_type.hl_group(status)] ~= nil, 'text group for ' .. status)
        ok(
          renderer.highlights[status_type.sign_hl_group(status)] ~= nil,
          'sign group for ' .. status
        )
      end
      ok(renderer.highlights['VcssignHeader'] ~= nil, 'group headers')
      ok(renderer.highlights['VcssignError'] ~= nil, 'the error placeholder')
    end,
  },
  {
    name = 'highlights are defined as defaults, so a user definition wins',
    fn = function()
      vim.api.nvim_set_hl(0, 'VcssignAdded', { fg = 0x123456 })
      renderer.define_highlights()
      eq(
        vim.api.nvim_get_hl(0, { name = 'VcssignAdded' }).fg,
        0x123456,
        'define_highlights must not stomp a user colour'
      )
      -- Everything else is defined exactly as documented, because `default =
      -- true` leaves the field alone once somebody set it.
      for group, link in pairs(renderer.highlights) do
        if group ~= 'VcssignAdded' then
          eq(vim.api.nvim_get_hl(0, { name = group }).link, link, 'default link for ' .. group)
        end
      end
      -- Leave the process as we found it: specs share one nvim, and a global
      -- colour left behind would hide a future "wrong colour" regression.
      vim.cmd('highlight clear VcssignAdded')
      renderer.define_highlights()
      eq(vim.api.nvim_get_hl(0, { name = 'VcssignAdded' }).link, 'DiffAdd')
    end,
  },
  {
    name = 'the placeholder distinguishes loading, failure and a clean tree',
    fn = function()
      local loading = renderer.for_repo(fake_repo({}, { has_loaded = false }))
      eq(#loading, 1)
      eq(loading[1].kind, 'banner')
      ok(loading[1].text:find('refreshing', 1, true), loading[1].text)

      local failed = renderer.for_repo(
        fake_repo({}, { has_loaded = false, last_error = 'fatal: not a git repository' })
      )
      eq(failed[1].kind, 'banner')
      ok(failed[1].text:find('not a git repository', 1, true), failed[1].text)

      local clean = renderer.for_repo(fake_repo({}))
      eq(clean[1].kind, 'banner')
      ok(clean[1].text:find('no changes', 1, true), clean[1].text)

      -- Rows win over the placeholder as soon as there is something to show.
      local listed = renderer.for_repo(fake_repo({ entry('a.txt', { worktree = 'modified' }) }))
      eq(#listed, 2)
      eq(listed[1].kind, 'header')
      eq(listed[2].kind, 'entry')
    end,
  },
  {
    name = 'a failure banner keeps the words that explain the failure',
    fn = function()
      local reason = 'fatal: not a git repository (or any of the parent directories): .git'
      local bufnr = scratch_buffer()
      -- 40 columns is the default sidebar width: the budget is 35 characters,
      -- and the reason alone is 66 — the classic case where trimming the head
      -- (right for a path) would leave only the parenthetical tail.
      renderer.draw(
        bufnr,
        renderer.for_repo(fake_repo({}, { has_loaded = false, last_error = reason }), 40)
      )
      local banner = renderer.items(bufnr)[1]
      eq(banner.kind, 'banner')
      eq(vim.fn.strchars(banner.text), 35, 'it fills the row and no more')
      eq(
        vim.fn.strcharpart(banner.text, vim.fn.strchars(banner.text) - 1, 1),
        '…',
        'the cut is marked'
      )
      ok(
        banner.text:find('fatal: not a git repository', 1, true),
        'the reason survives: ' .. banner.text
      )
      eq(line_hl(bufnr, 0), 'VcssignError', 'a failure reads as one')

      -- The other two placeholders are ordinary states, so they are not red.
      renderer.draw(bufnr, renderer.for_repo(fake_repo({}, { has_loaded = false }), 40))
      eq(line_hl(bufnr, 0), 'VcssignHeader', 'refreshing is not an error')
      renderer.draw(bufnr, renderer.for_repo(fake_repo({}), 40))
      ok(renderer.items(bufnr)[1].text:find('no changes', 1, true))
      eq(line_hl(bufnr, 0), 'VcssignHeader', 'a clean tree is not an error')
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
  },
  {
    name = 'a thousand rows render well inside the debounce window',
    fn = function()
      local statuses = { 'modified', 'added', 'deleted', 'untracked', 'conflicted' }
      local entries = {}
      for i = 1, 1000 do
        entries[i] = entry(string.format('src/dir%02d/file%04d.txt', i % 40, i), {
          index = i % 3 == 0 and statuses[(i % 5) + 1] or nil,
          worktree = statuses[(i % 5) + 1],
        })
      end
      local bufnr = scratch_buffer()
      local started = vim.uv.hrtime()
      local items = renderer.build(entries, { group_by = 'status', has_index = true, width = 40 })
      renderer.draw(bufnr, items)
      local elapsed_ms = (vim.uv.hrtime() - started) / 1e6
      eq(#items, 1000 + 3, 'one header per group plus every entry')
      ok(
        elapsed_ms < 200,
        string.format('1000 rows took %.1fms; the plan allows 200ms', elapsed_ms)
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end,
  },
}
