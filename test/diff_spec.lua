--- M6 Step 3: the built-in diff driver and its newline convention.
--- See impl/knowledge/signs/ §3 (D39/D43).
local diff = require('vcssign.diff')

local function guarded(fn)
  return function()
    local ran, err = pcall(fn)
    if not ran then
      error(err, 0)
    end
  end
end

return {
  {
    name = 'normalize strips exactly one trailing newline',
    fn = guarded(function()
      eq(diff.normalize(''), '')
      eq(diff.normalize('a'), 'a')
      eq(diff.normalize('a\n'), 'a')
      eq(diff.normalize('a\n\n'), 'a\n')
    end),
  },
  {
    name = 'split produces 1-based lines and never invents a phantom last line',
    fn = guarded(function()
      eq(diff.split(''), { '' })
      eq(diff.split('a'), { 'a' })
      eq(diff.split('a\n'), { 'a' })
      eq(diff.split('a\n\n'), { 'a', '' })
    end),
  },
  {
    name = 'join is split without the trailing newline',
    fn = guarded(function()
      eq(diff.join({}), '')
      eq(diff.join({ 'a' }), 'a')
      eq(diff.join({ 'a', 'b' }), 'a\nb')
      eq(diff.join(diff.split('a\nb\n')), 'a\nb')
    end),
  },
  {
    name = 'an empty baseline makes every line an `add`',
    fn = guarded(function()
      local hunks = diff.run('', 'a\nb')
      eq(#hunks, 1)
      eq(hunks[1].type, 'add')
      eq(hunks[1].removed, { start = 0, count = 0 })
      eq(hunks[1].added, { start = 1, count = 2 })
    end),
  },
  {
    name = 'two identical texts produce no hunks',
    fn = guarded(function()
      eq(diff.run('', ''), {})
      eq(diff.run('a\nb', 'a\nb'), {})
      eq(diff.run('a\nb\n', 'a\nb\n'), {})
    end),
  },
  {
    name = 'one changed line is one `change`',
    fn = guarded(function()
      local hunks = diff.run(diff.join({ 'a', 'b', 'c' }), diff.join({ 'a', 'B', 'c' }))
      eq(#hunks, 1)
      eq(hunks[1].type, 'change')
      eq(hunks[1].removed, { start = 2, count = 1 })
      eq(hunks[1].added, { start = 2, count = 1 })
    end),
  },
  {
    name = 'the newline convention is what keeps the last line from changing',
    fn = guarded(function()
      -- E5: the baseline ends in `\n`, the buffer never does.  Feeding the
      -- baseline through unchanged reports a bogus last-line change once the
      -- CR tolerance is out of the way (`ignore_cr_at_eol` happens to also
      -- absorb a missing final newline, so isolate the convention first).
      local opts = { ignore_cr_at_eol = false }
      eq(#diff.run('a\nb\n', 'a\nb', opts), 1)
      eq(diff.run(diff.normalize('a\nb\n'), diff.join({ 'a', 'b' }), opts), {})
    end),
  },
  {
    name = 'ignore_cr_at_eol hides a CRLF/LF difference, and can be overridden',
    fn = guarded(function()
      -- config.diff.ignore_cr_at_eol defaults to true.
      eq(diff.run('a\r\nb', 'a\nb'), {})
      local hunks = diff.run('a\r\nb', 'a\nb', { ignore_cr_at_eol = false })
      eq(#hunks, 1)
      eq(hunks[1].type, 'change')
    end),
  },
  {
    name = 'the algorithm option reaches the engine',
    fn = guarded(function()
      local a, b = diff.join({ 'a', 'b', 'c' }), diff.join({ 'a', 'X', 'c' })
      local myers = diff.run(a, b, { algorithm = 'myers' })
      local histogram = diff.run(a, b, { algorithm = 'histogram' })
      eq(#myers, 1)
      eq(myers, histogram)
    end),
  },
  {
    name = 'a large diff stays well under the interactive budget',
    fn = guarded(function()
      -- 20000 lines with isolated changes.  The hunks stay small on purpose:
      -- `diff.linematch = true` asks for linematch on *every* hunk however
      -- large, and linematch is quadratic in hunk size (one all-changed
      -- 20k-line hunk does not finish).  A bounded integer threshold is the
      -- escape hatch; see the note in lua/vcssign/diff.lua.
      local a, b = {}, {}
      for i = 1, 20000 do
        a[i] = 'line ' .. i
        b[i] = (i % 100 == 0) and ('changed ' .. i) or ('line ' .. i)
      end
      local started = vim.uv.hrtime()
      local hunks = diff.run(diff.join(a), diff.join(b))
      local ms = (vim.uv.hrtime() - started) / 1e6
      eq(#hunks, 200)
      -- myers measured at a few ms here; 200ms leaves room for CI.
      ok(ms < 200, string.format('20k-line diff took %.1fms', ms))
    end),
  },
}
