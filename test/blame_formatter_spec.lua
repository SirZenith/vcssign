--- The `<specifier>` formatter of the inline blame (signs §4, aligned with
--- gitsigns' `current_line_blame_formatter`).
---
--- Nothing here touches a repository, a buffer or a process: the cases pin down
--- how a `vcssign.BlameLine` becomes the text -- or the chunks -- that
--- `vcssign.blame` draws.
local blame_formatter = require('vcssign.blame_formatter')

--- A line as `git blame --line-porcelain` describes it.
---@param over? table<string, any>
---@return vcssign.BlameLine
local function porcelain(over)
  -- `false` removes a field: a Lua table cannot carry an explicit nil, so
  -- `tbl_extend` would keep the default one otherwise.
  local line = vim.tbl_extend('force', {
    rev = string.rep('2f786f84', 5),
    author = 'Ada Lovelace',
    author_name = 'Ada Lovelace',
    author_mail = 'ada@example.com',
    author_time = os.time({ year = 2020, month = 1, day = 2, hour = 12, min = 30 }),
    author_tz = '+0100',
    committer = 'Grace Hopper',
    committer_time = os.time({ year = 2020, month = 1, day = 3, hour = 12 }),
    summary = 'add the thing',
    filename = 'base.txt',
    lnum = 3,
    orig_lnum = 7,
    final_lnum = 3,
  }, over or {})
  for key, value in pairs(line) do
    if value == false then
      line[key] = nil
    end
  end
  return line
end

---@param over? table<string, any>
---@return table<string, any>
local function info(over)
  return blame_formatter.info(porcelain(over))
end

---@param elapsed integer  seconds before now
---@return string
local function ago(elapsed)
  return blame_formatter.relative_time(os.time() - elapsed)
end

return {
  {
    name = 'the placeholders of a porcelain line are the ones gitsigns documents',
    fn = function()
      local got = info()
      eq(got.rev, string.rep('2f786f84', 5), 'the full object id')
      eq(got.abbrev_sha, '2f786f84', 'and its abbreviation')
      eq(got.author, 'Ada Lovelace')
      eq(got.author_name, 'Ada Lovelace')
      eq(got.author_mail, 'ada@example.com', 'the bare address')
      eq(got.author_tz, '+0100')
      eq(got.summary, 'add the thing')
      eq(got.filename, 'base.txt')
      eq(got.lnum, 3)
      eq(got.orig_lnum, 7, 'the line number in the commit that introduced it')
      eq(got.committer, 'Grace Hopper')
    end,
  },
  {
    name = 'a specifier expands to its value, dates take a format',
    fn = function()
      local got = info()
      eq(
        blame_formatter.expand(' <author> <abbrev_sha> ', got),
        ' Ada Lovelace 2f786f84 ',
        'no format argument'
      )
      eq(blame_formatter.expand('<author_time:%Y-%m-%d>', got), '2020-01-02', 'strftime')
      eq(
        blame_formatter.expand('<author_time>', got),
        '2020-01-02',
        'a bare date specifier means YYYY-MM-DD'
      )
      eq(
        blame_formatter.expand('<author_mail> and <author_mail>', got),
        'ada@example.com and ada@example.com',
        'every occurrence is replaced'
      )
    end,
  },
  {
    name = 'a specifier the VCS cannot answer stays visible',
    fn = function()
      -- An adapter may have no subject (or a commit may have an empty
      -- message): `<summary>` must not silently vanish.
      local got = info({ summary = false, author_mail = false })
      eq(blame_formatter.expand(' <author> <summary>', got), ' Ada Lovelace <summary>')
      -- Which is why the default format has a variant without it.
      eq(blame_formatter.DEFAULT_NO_SUMMARY, ' <author>, <author_time:%R> ')
      local text = blame_formatter.format(blame_formatter.DEFAULT_NO_SUMMARY, got)
      ok(text:match('Ada Lovelace, .+ ago $'), 'the short form keeps author and time')
      ok(not text:find('<', 1, true), 'and shows no placeholder at all')
    end,
  },
  {
    name = 'a line nobody has committed is formatted through the _nc placeholders',
    fn = function()
      eq(
        info({ rev = string.rep('0', 40), author = 'Not Committed Yet' }).author,
        'Not Committed Yet'
      )
      eq(info({ rev = '-' }).author, 'Not Committed Yet', 'svn reports no commit as `-`')
      eq(info({ rev = '-' }).abbrev_sha, nil, 'and has no revision to show')
    end,
  },
  {
    name = 'relative_time is gitsigns %R',
    fn = function()
      eq(ago(0), 'a while ago', 'a commit made just now')
      eq(ago(30), '30 seconds ago')
      eq(ago(60), '1 minute ago')
      eq(ago(2 * 60 * 60), '2 hours ago')
      eq(ago(3 * 24 * 60 * 60), '3 days ago')
      eq(ago(31 * 24 * 60 * 60), '1 month ago')
      eq(ago(400 * 24 * 60 * 60), '1 year ago')
      eq(blame_formatter.relative_time(os.time() + 60), 'a while ago', 'a date in the future')
    end,
  },
  {
    name = 'a function formatter may answer chunks instead of text',
    fn = function()
      local info_ = info()
      local text, chunks = blame_formatter.format(function(_)
        return { { 'Ada ', 'X' }, { 'Lovelace', 'Y' } }
      end, info_)
      eq(text, 'Ada Lovelace', 'the chunks are joined for the text')
      eq(chunks, { { 'Ada ', 'X' }, { 'Lovelace', 'Y' } }, 'and handed over as virt_text')

      local plain = blame_formatter.format(function(bl)
        return bl.author .. '!'
      end, info_)
      eq(plain, 'Ada Lovelace!', 'a string answer has no chunks')
    end,
  },
  {
    name = 'a formatter that raises answers with the fallback instead',
    fn = function()
      local text, chunks = blame_formatter.format(function()
        error('boom')
      end, info())
      eq(text, ' <author>', 'the text is the fallback')
      eq(chunks, nil, 'and nothing is drawn apart from it')
      eq(
        blame_formatter.format(nil, info()),
        blame_formatter.expand(blame_formatter.DEFAULT, info()),
        'a nil formatter means the default'
      )
    end,
  },
}
