--- Current-line blame: the `current_line_blame` decoration and the `blame_line`
--- float of impl/knowledge/signs/ §4 / §6 (Step 11).
---
--- The decoration follows gitsigns: `current_line_blame_opts` decides where the
--- text goes (`virt_text`, `virt_text_pos`, `virt_text_priority`), how long the
--- cursor has to stand still (`delay`), whether the annotation belongs to the
--- focused window only (`use_focus`) and what it says (`current_line_blame_formatter`,
--- `_nc`, expanded by `vcssign.blame_formatter` -- the same placeholders gitsigns
--- documents).  The events are module-level (gitsigns' `setup()` shape) and the
--- per-window question (`is that window focused?`) is answered on every render,
--- so a cursor move in one window does not disturb another.
---
--- A blame is asked for **one line at a time** (`-L l,l`, perf P1-3) and cached per
--- line number: moving the cursor must not cost a process, and neither must
--- coming back to a line that was already answered.  The cache is keyed by the
--- buffer's `changedtick`, the options that shape the answer and the baseline
--- fingerprint (so a commit retires it), and svn -- which cannot blame a line
--- range (§6.3) -- is served by exactly the same cache: its adapter answers the
--- whole file, and the merge in `store()` keeps every line of it.
---
--- Neither the decoration nor the float is worth blocking on: both render from
--- whatever the cache holds and quietly do nothing when there is no answer, so a
--- failure here can never disturb the signs.
local api = vim.api
local base = require('vcssign.vcs.base')
local config = require('vcssign.config')
local debounce = require('vcssign.debounce')
local formatter = require('vcssign.blame_formatter')

local M = {}

local NS = 'vcssign_blame'

--- The group of the inline text: a commit's line of blame is commentary, so it
--- borrows `Comment` (that is what gitsigns' `GitSignsCurrentLineBlame` is).
local GROUP = 'VcssignBlame'

--- One decoration per buffer, so a render replaces the previous one instead of
--- stacking (gitsigns does the same with `id = 1`).
local MARK_ID = 1

function M.define_highlights()
  api.nvim_set_hl(0, GROUP, { link = 'Comment', default = true })
end

---@type integer?
M._ns = nil

--- The namespace of the inline blame (`vcssign_blame`, signs §4).
---@return integer
function M.namespace()
  if not M._ns then
    M._ns = api.nvim_create_namespace(NS)
  end
  return M._ns
end

--- `attach` is required lazily: it requires this module to hook a buffer up.
local function attached()
  return require('vcssign.attach')
end

---@class vcssign.blame.State
---@field call fun()      the debounced render
---@field cancel fun()    drop a render that has not fired yet

--- The watched buffers.
---@type table<integer, vcssign.blame.State>
M._bufs = {}

--- The last successful blame of a buffer, valid while the cache key matches.
---@class vcssign.blame.Entry
---@field key string          buffer text (changedtick) plus the shaping options
---@field stamp string?       the baseline fingerprint the lines were read under
---@field result vcssign.BlameResult  a sparse map: lines answered so far
---@field has_summary boolean  whether any cached line carries a commit subject

---@type table<integer, vcssign.blame.Entry>
M._cache = {}

---@type integer?
M._group = nil
local group_key = nil

--- The revision as it is worth showing: git's forty hex digits are noise, a
--- plain number (svn) is already short.
---@param rev string
---@return string
local function short_rev(rev)
  if rev:match('^%x+$') and #rev > 12 then
    return rev:sub(1, 8)
  end
  return rev
end

--- Whether a line has no commit behind it: git reports an all-zero sha with
--- `Not Committed Yet` as the author, svn omits the commit and reports `-`.
---@param bl vcssign.BlameLine
---@return boolean
local function uncommitted(bl)
  return bl.rev == '-' or bl.rev:match('^0+$') ~= nil
end

--- `<rev> <author> <date>`: the commit behind a line, or `Not Committed Yet`.
---@param bl vcssign.BlameLine
---@return string
function M.commit_text(bl)
  if uncommitted(bl) then
    return 'Not Committed Yet'
  end
  local parts = { short_rev(bl.rev) }
  if bl.author and bl.author ~= '' then
    parts[#parts + 1] = bl.author
  end
  if bl.time then
    parts[#parts + 1] = os.date('%Y-%m-%d', bl.time)
  end
  return table.concat(parts, ' ')
end

--- The format string for one line: the `_nc` variant for a line nobody has
--- committed yet, and -- for the default format only -- a variant without the
--- subject when the adapter has none (svn does not report `summary`).
---@param bl vcssign.BlameLine
---@param has_summary boolean
---@return string
local function format_of(bl, has_summary)
  local cfg = config.get()
  if uncommitted(bl) then
    return cfg.current_line_blame_formatter_nc
  end
  local fmt = cfg.current_line_blame_formatter
  if fmt == formatter.DEFAULT and not has_summary then
    return formatter.DEFAULT_NO_SUMMARY
  end
  return fmt
end

--- The inline annotation of one line, as the configuration formats it.
---@param bl vcssign.BlameLine
---@param opts? { has_summary?: boolean }  false: the adapter has no subject
---@return string
function M.line_text(bl, opts)
  local has_summary = opts == nil or opts.has_summary ~= false
  local text = formatter.format(format_of(bl, has_summary), formatter.info(bl))
  return text
end

--- The options that shape a blame answer.  They are part of the cache key: the
--- same file blamed with and without `-w` is two different answers.
---
--- The line *window* is deliberately **not** in the key: `from`/`to` say which
--- slice of the answer a call wants, not what the answer is.  Answers are cached
--- per line number instead (see `blame_for`).
---@param opts vcssign.BlameOpts
---@return string
local function options_key(opts)
  local extra = opts.extra_opts and table.concat(opts.extra_opts, ' ') or ''
  return string.format('%s:%s', tostring(opts.ignore_whitespace), extra)
end

--- Fold a fetched slice into the buffer's cache entry.
---
--- A new entry is made when the key or the baseline moved; otherwise the slice
--- is merged in, which is what makes the second look at a nearby line free (and
--- what makes svn's whole-file answer, which arrives on the first look, cover
--- every line of the buffer).
---@param bufnr integer
---@param key string
---@param stamp string?
---@param result vcssign.BlameResult
---@return vcssign.blame.Entry
local function store(bufnr, key, stamp, result)
  local entry = M._cache[bufnr]
  if not entry or entry.key ~= key or entry.stamp ~= stamp then
    entry = {
      key = key,
      stamp = stamp,
      result = { lines = {}, max_lineno = 0 },
      has_summary = false,
    }
  end
  for line, bl in pairs(result.lines or {}) do
    entry.result.lines[line] = bl
    if not entry.has_summary and bl.summary and bl.summary ~= '' then
      entry.has_summary = true
    end
  end
  entry.result.max_lineno = math.max(entry.result.max_lineno, result.max_lineno or 0)
  M._cache[bufnr] = entry
  return entry
end

--- The blame of one line of a buffer.
---
--- A blame costs a process, so the three decisions here are all about not paying
--- for one:
---
--- * **ask for the line window** (`-L l,l`), not the whole file — git then
---   answers with one line's attribution and parses one line (svn has no line
---   window, so its adapter ignores the window and answers the whole file; every
---   later line of that buffer is then free, perf §3.5);
--- * **cache per line number**, keyed by the buffer's `changedtick`, the options
---   that shape the answer and the baseline fingerprint — moving the cursor
---   costs nothing, because the line it moves to is usually already known;
--- * **compare the fingerprint** so "Not Committed Yet" stays honest: a commit,
---   a `git add` or an `svn commit` changes what the answer is without touching
---   the buffer's text.
---
--- `cb` gets an error when the buffer cannot be blamed at all (no repository, or
--- no `blame` capability); the adapter's own error passes through.  A failed
--- fetch is not cached, so the next cursor move retries it.
---@param bufnr integer
---@param lnum integer
---@param cb fun(err: string?, entry: vcssign.blame.Entry?, st: vcssign.AttachState?)
local function blame_for(bufnr, lnum, cb)
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return cb(string.format('buffer %d is not loaded', bufnr))
  end
  local opts = config.get().current_line_blame_opts
  local key = string.format('%d:%s', vim.b[bufnr].changedtick, options_key(opts))
  local state = attached().state(bufnr)
  local stamp = base.stamp(state and state.system, state and state.root)
  local cached = M._cache[bufnr]
  if cached and cached.key == key and cached.stamp == stamp and cached.result.lines[lnum] then
    return cb(nil, cached, state)
  end
  attached().ready(bufnr, function(err, st)
    if not st then
      return cb(err)
    end
    if not st.system.capabilities.blame then
      return cb(string.format('%s: blame is not supported', st.system.name))
    end
    --- Ask once with the line window, and once without it when the window is
    --- refused: a line that only exists in the buffer (an unsaved insertion) is
    --- past the end of the file git can see, and the whole-file answer still
    --- covers the lines that do exist.
    local function ask(window, retried)
      local ask_opts = opts
      if window then
        ask_opts = vim.tbl_extend('force', opts, { from = lnum, to = lnum })
      end
      st.system.blame(st.root, st.rel, ask_opts, function(berr, result)
        if berr and window and not retried then
          return ask(false, true)
        end
        if berr then
          return cb(berr)
        end
        cb(nil, store(bufnr, key, stamp, result), st)
      end)
    end
    ask(true, false)
  end)
end

--- The window showing `bufnr`, or nil when none does.
---@param bufnr integer
---@return integer?
local function window_for(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end
  return win
end

--- Whether `win` is the focused window.
---
--- This is gitsigns' check, and it is deliberately about the *current* window:
--- `use_focus` means "only the window the user is in", so a split showing the
--- same buffer (or a float) is not annotated.  Switching away clears the
--- annotation through `BufLeave`, which is in the reset events.
---@param win integer
---@return boolean
local function focused(win)
  return api.nvim_get_current_win() == win
end

--- Whether the annotation may be drawn right now.
---
--- The fetch can take as long as a process does, so everything that made the
--- annotation wanted is asked twice: once before asking the VCS and once when
--- the answer arrives.  (A fetch that started while the user was in the buffer
--- must not draw into a window the user has since left.)
---@param bufnr integer
---@param win integer
---@param lnum integer
---@return boolean
local function still_wanted(bufnr, win, lnum)
  if not config.get().current_line_blame then
    return false
  end
  if api.nvim_get_mode().mode:sub(1, 1) == 'i' then
    return false
  end
  if window_for(bufnr) ~= win or api.nvim_win_get_cursor(win)[1] ~= lnum then
    return false
  end
  local opts = config.get().current_line_blame_opts
  if opts.use_focus and not focused(win) then
    return false
  end
  return not api.nvim_win_call(win, function()
    return vim.fn.foldclosed(lnum) ~= -1
  end)
end

--- Draw the inline blame of the buffer's current line (`current_line_blame`).
---
--- Only that one line is decorated, and the mark is anchored to it: it travels
--- with the text and every render replaces the previous one (same extmark id).
---@param bufnr integer
function M.render(bufnr)
  local win = window_for(bufnr)
  if not win then
    return
  end
  local lnum = api.nvim_win_get_cursor(win)[1]
  if not still_wanted(bufnr, win, lnum) then
    return
  end
  blame_for(bufnr, lnum, function(err, entry)
    -- Blame is a decoration: a buffer that cannot be blamed (or that the
    -- cursor, the switch or the focus has left) is not worth a message.
    if err or not entry or not still_wanted(bufnr, win, lnum) then
      return
    end
    local opts = config.get().current_line_blame_opts
    local bl = entry.result.lines[lnum]
    if not bl then
      return
    end
    local info = formatter.info(bl)
    local text, chunks = formatter.format(format_of(bl, entry.has_summary), info)
    vim.b[bufnr].vcssign_blame_line = text
    vim.b[bufnr].vcssign_blame_line_dict = info
    if not opts.virt_text then
      return
    end
    local pos = opts.virt_text_pos
    if pos == 'right_align' then
      local win_width = api.nvim_win_get_width(win)
      local textoff = vim.fn.getwininfo(win)[1].textoff
      local line = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
      local used = textoff + vim.fn.strdisplaywidth(line) + vim.fn.strdisplaywidth(text)
      if used + 1 > win_width then
        pos = 'eol'
      end
    end
    api.nvim_buf_set_extmark(bufnr, M.namespace(), lnum - 1, 0, {
      id = MARK_ID,
      virt_text = chunks or { { text, GROUP } },
      virt_text_pos = pos,
      priority = opts.virt_text_priority,
      hl_mode = 'combine',
    })
  end)
end

--- Clear the inline blame of one buffer (the mark and the `vim.b` record).
---@param bufnr integer
function M.clear(bufnr)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, M.namespace(), 0, -1)
  vim.b[bufnr].vcssign_blame_line = nil
  vim.b[bufnr].vcssign_blame_line_dict = nil
end

--- The module-level events, in gitsigns' shape (`setup()`): a cursor that moves
--- re-renders after `delay`, insert mode and leaving the buffer drop the
--- annotation at once, and a focus change matters only with `use_focus`.
local function configure()
  local opts = config.get().current_line_blame_opts
  local key =
    string.format('%s:%s', tostring(opts.use_focus), tostring(config.get().current_line_blame))
  if M._group and group_key == key then
    return
  end
  if M._group then
    pcall(api.nvim_del_augroup_by_id, M._group)
  end
  group_key = key
  M._group = api.nvim_create_augroup('vcssign_blame', { clear = true })
  local update = { 'CursorMoved', 'CursorMovedI', 'BufEnter', 'WinResized' }
  local reset = { 'InsertEnter', 'BufLeave' }
  if opts.use_focus then
    update[#update + 1] = 'FocusGained'
    reset[#reset + 1] = 'FocusLost'
  end
  api.nvim_create_autocmd(update, {
    group = M._group,
    callback = function(args)
      local state = M._bufs[args.buf]
      if not state then
        return
      end
      M.clear(args.buf)
      if config.get().current_line_blame then
        state.call()
      end
    end,
  })
  api.nvim_create_autocmd(reset, {
    group = M._group,
    callback = function(args)
      M.clear(args.buf)
    end,
  })
  -- `fileformat` / `bomb` / `eol` decide what the file's lines are; a change
  -- there invalidates the annotation (gitsigns' `on_lines`/`OptionSet` pair).
  api.nvim_create_autocmd('OptionSet', {
    group = M._group,
    pattern = { 'fileformat', 'bomb', 'eol' },
    callback = function(args)
      M.clear(args.buf)
    end,
  })
end

--- (Re)create the module-level events.  Called on every attach and whenever
--- `toggle_current_line_blame` runs, because `use_focus` decides which events
--- matter.
function M.setup()
  configure()
end

--- Start watching `bufnr`: the decoration follows the cursor after
--- `current_line_blame_opts.delay` ms, and a text change drops it right away --
--- it described lines that no longer exist.
---@param bufnr integer
function M.attach(bufnr)
  if M._bufs[bufnr] then
    return
  end
  local call, cancel = debounce.debounce_trailing({
    timeout = function()
      return config.get().current_line_blame_opts.delay
    end,
  }, function()
    M.render(bufnr)
  end)
  M._bufs[bufnr] = { call = call, cancel = cancel }
  configure()
  if config.get().current_line_blame then
    call()
  end
end

--- Stop watching `bufnr`, drop its pending render, its decoration and its
--- cached blame.
---
--- The timer must go: `Repo:dispose()` and `VimLeavePre` have to leave no live
--- handles behind (the `uv_count('timer')` assertion of autocmds_spec).
---@param bufnr integer
function M.detach(bufnr)
  local state = M._bufs[bufnr]
  if state then
    state.cancel()
    M._bufs[bufnr] = nil
  end
  M._cache[bufnr] = nil
  M.clear(bufnr)
end

--- Re-render every watched buffer: `toggle_current_line_blame` turns the
--- decoration on (after the delay) or clears it on the spot.
function M.refresh_all()
  configure()
  for bufnr in pairs(M._bufs) do
    M.clear(bufnr)
    if config.get().current_line_blame then
      M._bufs[bufnr].call()
    end
  end
end

--- `blame_line`: the blame of one line in the float of `vcssign.preview`, with
--- the line itself for context.  Calling it on the line it already shows closes
--- it again.
---@param bufnr integer
---@param lnum integer
---@param cb fun(err: string?, shown: boolean?)
function M.line(bufnr, lnum, cb)
  local preview = require('vcssign.preview')
  if preview.is_open(bufnr, lnum) then
    preview.close()
    return cb(nil, false)
  end
  blame_for(bufnr, lnum, function(err, entry, st)
    if err then
      return cb(err)
    end
    local bl = entry and entry.result.lines[lnum]
    if not bl then
      return cb(string.format('no blame for line %d', lnum))
    end
    local text = { M.commit_text(bl) }
    if not uncommitted(bl) and bl.summary and bl.summary ~= '' then
      text[#text + 1] = bl.summary
    end
    text[#text + 1] = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ''
    preview.open(bufnr, lnum, text, {
      filetype = st and st.system.name == 'git' and 'git' or nil,
      title = string.format(
        ' blame %s:%d ',
        vim.fn.fnamemodify(api.nvim_buf_get_name(bufnr), ':t'),
        lnum
      ),
    })
    cb(nil, true)
  end)
end

return M
