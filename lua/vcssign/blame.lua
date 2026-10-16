--- Current-line blame: the `current_line_blame` decoration and the
--- `blame_line` float of impl/init/07-signs-in-signcolumn.md §4 / §6 (Step 11).
---
--- Blame is a whole-file question whose answer is reused while the buffer's text
--- does not change: every line of the file gets one attribution, and moving the
--- cursor must not cost a process.  The cache is therefore keyed by the
--- buffer's `changedtick`, and svn -- which cannot blame a line range (§6.3) --
--- is served by exactly the same cache.
---
--- Neither the decoration nor the float is worth blocking on: both render from
--- whatever the cache holds and quietly do nothing when there is no answer, so a
--- failure here can never disturb the signs.
local api = vim.api
local config = require('vcssign.config')
local debounce = require('vcssign.debounce')

local M = {}

local NS = 'vcssign_blame'

--- The group of the inline text: a commit's line of blame is commentary, so it
--- borrows `Comment` (that is what gitsigns' `GitSignsCurrentLineBlame` is).
local GROUP = 'VcssignBlame'

function M.define_highlights()
  api.nvim_set_hl(0, GROUP, { link = 'Comment', default = true })
end

---@type integer?
M._ns = nil

--- The namespace of the inline blame (`vcssign_blame`, 07 §4).
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
---@field ids integer[]   the autocmds to delete on detach

--- The watched buffers.
---@type table<integer, vcssign.blame.State>
M._bufs = {}

--- The last successful blame of a buffer, valid while `changedtick` matches.
---@type table<integer, { tick: integer, result: vcssign.BlameResult }>
M._cache = {}

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

--- The inline decoration of a line: the commit, plus the subject when the
--- adapter knows one (git does, svn has no `summary`).
---@param bl vcssign.BlameLine
---@return string
function M.line_text(bl)
  local text = M.commit_text(bl)
  if not uncommitted(bl) and bl.summary and bl.summary ~= '' then
    text = text .. ' ' .. bl.summary
  end
  return text
end

--- The blame of a buffer, from the cache when its text has not changed.
---
--- `cb` gets an error when the buffer cannot be blamed at all (no repository,
--- or no `blame` capability); the adapter's own error passes through.  A failed
--- fetch is not cached, so the next cursor move retries it.
---@param bufnr integer
---@param cb fun(err: string?, result: vcssign.BlameResult?, st: vcssign.AttachState?)
local function blame_for(bufnr, cb)
  if not api.nvim_buf_is_valid(bufnr) or not api.nvim_buf_is_loaded(bufnr) then
    return cb(string.format('buffer %d is not loaded', bufnr))
  end
  local tick = vim.b[bufnr].changedtick
  local cached = M._cache[bufnr]
  if cached and cached.tick == tick then
    return cb(nil, cached.result)
  end
  attached().ready(bufnr, function(err, st)
    if not st then
      return cb(err)
    end
    if not st.system.capabilities.blame then
      return cb(string.format('%s: blame is not supported', st.system.name))
    end
    st.system.blame(st.root, st.rel, {}, function(berr, result)
      if berr then
        return cb(berr)
      end
      M._cache[bufnr] = { tick = tick, result = result }
      cb(nil, result, st)
    end)
  end)
end

--- The line the cursor is on, or nil when no window shows the buffer.
---@param bufnr integer
---@return integer?
local function cursor_line(bufnr)
  local win = vim.fn.bufwinid(bufnr)
  if win == -1 then
    return nil
  end
  return api.nvim_win_get_cursor(win)[1]
end

--- Draw the inline blame of the buffer's current line (`current_line_blame`).
---
--- Only that one line is decorated, and the mark is anchored to it: it travels
--- with the text and every re-render clears the previous one.
---@param bufnr integer
function M.render(bufnr)
  M.clear(bufnr)
  if not config.get().current_line_blame then
    return
  end
  local lnum = cursor_line(bufnr)
  if not lnum then
    return
  end
  blame_for(bufnr, function(err, result)
    -- Blame is a decoration: a buffer that cannot be blamed (or that the
    -- cursor has already left) is not worth a message.
    if err or not result or not config.get().current_line_blame then
      return
    end
    local at = cursor_line(bufnr)
    local bl = result.lines[lnum]
    if not bl or at ~= lnum then
      return
    end
    api.nvim_buf_set_extmark(bufnr, M.namespace(), lnum - 1, 0, {
      virt_text = { { ' ' .. M.line_text(bl) .. ' ', GROUP } },
      virt_text_pos = config.get().current_line_blame_opts.virt_text_pos,
      priority = vim.hl.priorities.user,
    })
  end)
end

--- Clear the inline blame of one buffer.
---@param bufnr integer
function M.clear(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, M.namespace(), 0, -1)
  end
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
  local ids = {}
  local function on(events, fn)
    ids[#ids + 1] = api.nvim_create_autocmd(events, { buffer = bufnr, callback = fn })
  end
  on({ 'CursorMoved', 'CursorMovedI' }, call)
  on({ 'TextChanged', 'TextChangedI' }, function()
    M.clear(bufnr)
    call()
  end)
  M._bufs[bufnr] = { call = call, cancel = cancel, ids = ids }
  call()
end

--- Stop watching `bufnr`, drop its pending render, its autocmds, its
--- decoration and its cached blame.
---
--- The timer must go: `Repo:dispose()` and `VimLeavePre` have to leave no live
--- handles behind (the `uv_count('timer')` assertion of autocmds_spec).
---@param bufnr integer
function M.detach(bufnr)
  local state = M._bufs[bufnr]
  if state then
    state.cancel()
    for _, id in ipairs(state.ids) do
      pcall(api.nvim_del_autocmd, id)
    end
    M._bufs[bufnr] = nil
  end
  M._cache[bufnr] = nil
  M.clear(bufnr)
end

--- Re-render every watched buffer: `toggle_current_line_blame` turns the
--- decoration on (after the delay) or clears it on the spot.
function M.refresh_all()
  for bufnr in pairs(M._bufs) do
    if config.get().current_line_blame then
      M._bufs[bufnr].call()
    else
      M.clear(bufnr)
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
  blame_for(bufnr, function(err, result, st)
    if err then
      return cb(err)
    end
    local bl = result and result.lines[lnum]
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
