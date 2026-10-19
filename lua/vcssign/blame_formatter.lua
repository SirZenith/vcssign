--- Blame formatting: gitsigns' `<specifier>` formatter (signs §4).
---
--- gitsigns renders the inline blame through `current_line_blame_formatter`, a
--- string of `<specifiers>` expanded against the commit behind the line, and
--- `current_line_blame_formatter_nc` for lines that are not committed yet.  A
--- formatter may also be a function, which returns either the text or a list of
--- `{ text, highlight }` chunks.
---
--- Nothing here knows about buffers or processes: it maps a
--- `vcssign.BlameLine` onto the placeholders and expands a format string, which
--- is what `test/blame_formatter_spec.lua` pins down.
local M = {}

--- gitsigns' default format, verbatim.
---@type string
M.DEFAULT = ' <author>, <author_time:%R> - <summary> '

--- What `DEFAULT` collapses to on a VCS that cannot answer `<summary>` (svn
--- keeps no commit subject in `blame --xml`): leaving the placeholder in would
--- print the literal `<summary>` at the end of every line.
---@type string
M.DEFAULT_NO_SUMMARY = ' <author>, <author_time:%R> '

--- The specifiers a format string may use.  A specifier the adapter cannot
--- answer is left as written (gitsigns' behaviour) -- that is how a typo in a
--- custom formatter stays visible instead of turning into silence.
---@type table<string, true>
M.SPECIFIERS = {
  abbrev_sha = true,
  orig_lnum = true,
  final_lnum = true,
  author = true,
  author_mail = true,
  author_time = true,
  author_tz = true,
  committer = true,
  committer_mail = true,
  committer_time = true,
  committer_tz = true,
  summary = true,
  previous = true,
  filename = true,
}

--- `4 months ago`: gitsigns' `%R` time format.
---@param time integer  seconds since the epoch
---@return string
function M.relative_time(time)
  local elapsed = os.time() - time
  if elapsed <= 0 then
    return 'a while ago'
  end
  local units = {
    { 365 * 24 * 60 * 60, 'year' },
    { 30 * 24 * 60 * 60, 'month' },
    { 24 * 60 * 60, 'day' },
    { 60 * 60, 'hour' },
    { 60, 'minute' },
    { 1, 'second' },
  }
  for _, unit in ipairs(units) do
    local seconds, name = unit[1], unit[2]
    if elapsed >= seconds then
      local n = math.floor(elapsed / seconds)
      return string.format('%d %s%s ago', n, name, n == 1 and '' or 's')
    end
  end
  return 'a while ago'
end

--- The date of `time` through `os.date`, with gitsigns' `%R` (relative) on top
--- and `%Y-%m-%d` as the format of a bare `<author_time>`.
---@param fmt string
---@param time integer
---@return string
local function expand_date(fmt, time)
  if fmt == '%R' then
    return M.relative_time(time)
  end
  return os.date(fmt, time)
end

--- `<author_time:%R>` -> `4 months ago`, `<abbrev_sha>` -> `2f786f84`.
---
--- The loop is bounded like gitsigns': a format string is user input, and a
--- pathological one must not spin (there is nothing to expand past the last
--- specifier, so the bound is only a safety net).
---@param fmt string
---@param info table<string, any>
---@return string
function M.expand(fmt, info)
  local out = {}
  local rest = fmt
  for _ = 1, 32 do
    -- `<name>` or `<name:format>`
    local scol, ecol, match, key, arg = rest:find('(<([^:>]+):?([^>]*)>)')
    if not match then
      break
    end
    out[#out + 1] = rest:sub(1, scol - 1)
    rest = rest:sub(ecol + 1)

    local value = info[key]
    if value then
      if type(value) == 'table' then
        value = table.concat(value, '\n')
      end
      if key:sub(-5) == '_time' then
        -- `_time` values are epoch seconds; a format is required to turn them
        -- into text, so a bare specifier means the date.
        value = expand_date(arg == '' and '%Y-%m-%d' or arg, value)
      end
      match = tostring(value)
    end
    out[#out + 1] = match
  end
  out[#out + 1] = rest
  return table.concat(out)
end

--- The placeholders of one blame line.
---
--- Every field a VCS cannot answer is simply absent, so `<summary>` on svn
--- stays visible; `author` is the one field that is always present, because
--- `current_line_blame_formatter_nc` (gitsigns' `' <author>'`) leans on it.
---@param bl vcssign.BlameLine
---@return table<string, any>
function M.info(bl)
  local nc = bl.rev == '-' or bl.rev:match('^0+$') ~= nil
  local name = bl.author_name or bl.author
  local info = {
    author = nc and 'Not Committed Yet' or name,
    author_name = nc and 'Not Committed Yet' or name,
  }
  if not nc then
    local rev = bl.rev or ''
    info.rev = rev
    info.abbrev_sha = rev:match('^%x+$') and #rev > 12 and rev:sub(1, 8) or rev
  end
  -- The porcelain fields, copied as they come: a nil one leaves its specifier
  -- in the text, which is how a formatter naming a field this repository does
  -- not have stays diagnosable.
  for _, key in ipairs({
    'lnum',
    'orig_lnum',
    'final_lnum',
    'kind',
    'author_mail',
    'author_time',
    'author_tz',
    'committer',
    'committer_mail',
    'committer_time',
    'committer_tz',
    'summary',
    'previous',
    'filename',
  }) do
    if bl[key] ~= nil and bl[key] ~= '' then
      info[key] = bl[key]
    end
  end
  return info
end

--- Render `fmt` against `info`.
---
--- The formatter is either a string (expanded) or a function taking the
--- placeholder table and returning either the text or a list of
--- `{ text, highlight }` chunks.  `nil` keeps the caller's text:
---@param fmt string|fun(info: table): string|table|nil
---@param info table<string, any>
---@return string text
---@return table[]? chunks  `virt_text` chunks, when the formatter returned them
function M.format(fmt, info)
  if type(fmt) == 'function' then
    local ok, value = pcall(fmt, info)
    if not ok then
      return ' <author>', nil
    end
    if type(value) == 'table' then
      local chunks = {}
      for _, chunk in ipairs(value) do
        if type(chunk) == 'table' and type(chunk[1]) == 'string' and chunk[1] ~= '' then
          chunks[#chunks + 1] = { chunk[1], chunk[2] }
        end
      end
      local text = {}
      for _, chunk in ipairs(chunks) do
        text[#text + 1] = chunk[1]
      end
      return table.concat(text), chunks
    end
    return tostring(value), nil
  end
  return M.expand(fmt or M.DEFAULT, info), nil
end

return M
