--- M6 Step 3: the hunk model and the patch builder.
--- See impl/init/07-signs-in-signcolumn.md §3 (D40/D41).
local hunk = require('vcssign.hunk')
local helpers = require('helpers')

--- Run a case, then drop the scratch repositories it made even when it failed.
local function guarded(fn)
  return function()
    local ran, err = pcall(fn)
    helpers.cleanup()
    if not ran then
      error(err, 0)
    end
  end
end

--- `git -C <dir> ...`, feeding `stdin` when given.
---@param dir string
---@param args string[]
---@param stdin? string
---@return vim.SystemCompleted
local function git(dir, args, stdin)
  local cmd = { 'git', '-C', dir }
  vim.list_extend(cmd, args)
  return vim.system(cmd, { text = true, stdin = stdin }):wait()
end

--- `hunk.from_indices` with a single group spelled inline.
local function one(start_a, count_a, start_b, count_b)
  return hunk.from_indices({ { start_a, count_a, start_b, count_b } })[1]
end

--- A hunk with `added.lines` attached, as `filter_common` compares content.
local function node_hunk(start, text)
  return {
    type = 'change',
    removed = { start = start, count = 1, lines = { text } },
    added = { start = start, count = 1, lines = { text } },
  }
end

return {
  {
    name = 'a pure insertion is an `add`, with an empty removed side',
    fn = guarded(function()
      local h = one(0, 0, 1, 2)
      eq(h.type, 'add')
      eq(h.removed, { start = 0, count = 0 })
      eq(h.added, { start = 1, count = 2 })
    end),
  },
  {
    name = 'an insertion after the first line keeps both starts on the right side',
    fn = guarded(function()
      local h = one(1, 0, 2, 1)
      eq(h.type, 'add')
      eq(h.removed, { start = 1, count = 0 })
      eq(h.added, { start = 2, count = 1 })
    end),
  },
  {
    name = 'a pure deletion is a `delete`, with an empty added side',
    fn = guarded(function()
      local h = one(2, 1, 1, 0)
      eq(h.type, 'delete')
      eq(h.removed, { start = 2, count = 1 })
      eq(h.added, { start = 1, count = 0 })
    end),
  },
  {
    name = 'removing the first line is a `topdelete`',
    fn = guarded(function()
      eq(one(1, 1, 0, 0).type, 'topdelete')
      eq(one(1, 3, 0, 0).type, 'topdelete')
      -- Only the *first* line is special.
      eq(one(2, 1, 0, 0).type, 'delete')
    end),
  },
  {
    name = 'lines on both sides are a `change`',
    fn = guarded(function()
      eq(one(2, 1, 2, 1).type, 'change')
      eq(one(2, 1, 2, 4).type, 'change')
    end),
  },
  {
    name = 'removing more than is added stays a `change`, not a `changedelete`',
    fn = guarded(function()
      -- `changedelete` is a rendering choice; the model does not split it out
      -- (D40).
      local h = one(2, 3, 2, 1)
      eq(h.type, 'change')
      eq(h.removed, { start = 2, count = 3 })
      eq(h.added, { start = 2, count = 1 })
    end),
  },
  {
    name = 'an empty indices list yields no hunks',
    fn = guarded(function()
      eq(hunk.from_indices({}), {})
      eq(hunk.from_indices(nil), {})
    end),
  },
  {
    name = 'sort orders by the new buffer, then the old, and does not mutate',
    fn = guarded(function()
      local a = one(5, 1, 5, 3) -- added.start=5
      local b = one(2, 4, 3, 1) -- added.start=3, removed.start=2
      local c = one(2, 1, 9, 2) -- added.start=9
      local d = one(2, 2, 3, 5) -- added.start=3, removed.start=2 (ties with b)
      local sorted = hunk.sort({ a, b, c, d })
      eq({
        sorted[1].added.count,
        sorted[2].added.count,
        sorted[3].added.count,
        sorted[4].added.count,
      }, { 1, 5, 3, 2 })
      -- The input keeps its original order.
      eq({ a.added.count, b.added.count, c.added.count, d.added.count }, { 3, 1, 2, 5 })
    end),
  },
  {
    name = 'sort is stable for hunks that share a start line',
    fn = guarded(function()
      local a, b, c = one(5, 1, 5, 9), one(5, 1, 5, 1), one(5, 1, 5, 5)
      local sorted = hunk.sort({ a, b, c })
      eq({ sorted[1].added.count, sorted[2].added.count, sorted[3].added.count }, { 9, 1, 5 })
    end),
  },
  {
    name = 'filter_common drops the hunks the filter already covers',
    fn = guarded(function()
      local still_unstaged = node_hunk(9, 'Y')
      local both = { node_hunk(5, 'X'), still_unstaged }
      -- The index already introduces X on line 5, so it is not unstaged any more.
      eq(hunk.filter_common(both, { node_hunk(5, 'X') }), { still_unstaged })
    end),
  },
  {
    name = 'filter_common keeps a hunk whose content differs at the same start',
    fn = guarded(function()
      local a = { node_hunk(5, 'X') }
      -- Same line, different text: not the same change, so it survives.
      eq(#hunk.filter_common(a, { node_hunk(5, 'Z') }), 1)
    end),
  },
  {
    name = 'filter_common with no filter returns the input, and nil stays nil',
    fn = guarded(function()
      local a = { node_hunk(1, 'A'), node_hunk(4, 'B') }
      eq(#hunk.filter_common(a, {}), 2)
      eq(#hunk.filter_common(a, nil), 2)
      eq(hunk.filter_common(nil, nil), nil)
    end),
  },
  {
    name = 'lines_of slices the old and new line lists',
    fn = guarded(function()
      local h = one(2, 2, 2, 1)
      local lines = hunk.lines_of(h, { 'a', 'b', 'c', 'd' }, { 'a', 'x', 'd' })
      eq(lines.removed, { 'b', 'c' })
      eq(lines.added, { 'x' })
    end),
  },
  {
    name = 'lines_of is empty on the side a one-sided hunk leaves blank',
    fn = guarded(function()
      local lines = hunk.lines_of(one(0, 0, 1, 1), {}, { 'new' })
      eq(lines.removed, {})
      eq(lines.added, { 'new' })
    end),
  },
  {
    name = 'build_patch writes a zero-context header, drops ,1 and ends with \\n',
    fn = guarded(function()
      local h = one(1, 1, 1, 2)
      eq(
        hunk.build_patch(h, { 'base' }, { 'BASE', 'more' }, 'base.txt'),
        'diff --git a/base.txt b/base.txt\n'
          .. '--- a/base.txt\n'
          .. '+++ b/base.txt\n'
          .. '@@ -1 +1,2 @@\n'
          .. '-base\n'
          .. '+BASE\n'
          .. '+more\n'
      )
    end),
  },
  {
    name = 'build_patch normalises backslashes in the relative path',
    fn = guarded(function()
      local patch = hunk.build_patch(one(1, 1, 1, 1), { 'a' }, { 'b' }, 'sub\\file.txt')
      ok(patch:find('diff --git a/sub/file.txt b/sub/file.txt', 1, true) ~= nil)
      ok(patch:find('+++ b/sub/file.txt', 1, true) ~= nil)
    end),
  },
  {
    name = 'build_patch can emit the no-newline-at-eof marker',
    fn = guarded(function()
      local patch = hunk.build_patch(
        one(1, 1, 1, 1),
        { 'a' },
        { 'b' },
        'f.txt',
        { base_no_nl_at_eof = true, buf_no_nl_at_eof = true }
      )
      eq(patch:sub(-28), '\\ No newline at end of file\n')
      ok(patch:find('-a\n\\ No newline at end of file\n+b\n', 1, true) ~= nil)
    end),
  },
  {
    name = 'a generated change patch is accepted by git apply --cached --unidiff-zero',
    fn = guarded(function()
      local dir = helpers.git_repo('hunk-apply-change')
      -- The committed base.txt is exactly `base\n`.
      local h = one(1, 1, 1, 2)
      local patch = hunk.build_patch(h, { 'base' }, { 'BASE', 'more' }, 'base.txt')
      local res = git(dir, { 'apply', '--cached', '--unidiff-zero', '-' }, patch)
      eq(res.code, 0, res.stderr)
      eq(git(dir, { 'show', ':base.txt' }).stdout, 'BASE\nmore\n')
    end),
  },
  {
    name = 'a generated top-insertion patch applies to the index',
    fn = guarded(function()
      local dir = helpers.git_repo('hunk-apply-add')
      local h = one(0, 0, 1, 1)
      local patch = hunk.build_patch(h, { 'base' }, { 'new', 'base' }, 'base.txt')
      local res = git(dir, { 'apply', '--cached', '--unidiff-zero', '-' }, patch)
      eq(res.code, 0, res.stderr)
      eq(git(dir, { 'show', ':base.txt' }).stdout, 'new\nbase\n')
    end),
  },
  {
    name = 'a generated deletion patch applies to the index',
    fn = guarded(function()
      local dir = helpers.git_repo('hunk-apply-delete')
      helpers.write(dir .. '/base.txt', 'a\nb\nc\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'three' })
      local h = one(2, 1, 1, 0)
      local patch = hunk.build_patch(h, { 'a', 'b', 'c' }, { 'a', 'c' }, 'base.txt')
      local res = git(dir, { 'apply', '--cached', '--unidiff-zero', '-' }, patch)
      eq(res.code, 0, res.stderr)
      eq(git(dir, { 'show', ':base.txt' }).stdout, 'a\nc\n')
    end),
  },
}
