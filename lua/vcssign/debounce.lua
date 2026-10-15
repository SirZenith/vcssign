--- Trailing-edge debouncing.
---
--- Ported from gitsigns.nvim (`lua/gitsigns/debounce.lua`), which is MIT
--- licensed:
---
---   MIT License
---   Copyright (c) 2020 Lewis Russell
---   https://github.com/lewis6991/gitsigns.nvim
---
--- Two modifications:
---
---   1. `debounce_trailing` also returns a `cancel` function.  gitsigns keeps
---      its pending timers in a closure-local table with no way to reach them,
---      which is fine for a buffer-local plugin but not here: `Repo:dispose()`
---      has to leave *zero* live handles behind (impl/init/02-repo-runtime.md
---      §5.4 asserts it), and a timer that outlives its repo would fire a
---      refresh against a disposed object.
---   2. The debounced call is dispatched with `vim.schedule`.  libuv timer
---      callbacks run in a fast event context (verified), so calling `fn`
---      directly — as gitsigns does — would forbid `vim.system` and every vim
---      API inside it.  Cancelling between the timer firing and the scheduled
---      call is handled with a per-id generation counter, because `vim.schedule`
---      itself cannot be un-scheduled.
local uv = vim.uv

local M = {}

---@class vcssign.debounce.Opts
---@field timeout integer|fun(): integer   ms
---@field hash? integer|fun(...): any      derives the debounce id from the arguments

--- Debounce a function on the trailing edge.
---
--- Example waveform
---   Time:      0  1  2  3  4  5  6  7  8  9
---   Input:     |  |     |           |
---   Debounced:          |                 |
---
---   The function is called at 0, 1, 3 and 7; with a 3 unit period the
---   debounced function fires at 3 and 9.
---@generic F: function
---@param opts vcssign.debounce.Opts|integer|fun(): integer
---@param fn F
---@return F debounced
---@return fun() cancel  drop every pending call without running `fn`
function M.debounce_trailing(opts, fn)
  local timeout ---@type (integer|fun(): integer)?
  local hash ---@type (integer|fun(...): any)?

  if type(opts) == 'table' then
    timeout, hash = opts.timeout, opts.hash
  else
    timeout = opts
  end

  -- Normalise a numeric `hash` (an argument index) to a function.
  if type(hash) == 'number' then
    local hash_i = hash
    ---@return any
    hash = function(...)
      return select(hash_i, ...)
    end
  elseif type(hash) ~= 'function' then
    hash = nil
  end

  -- Normalise a numeric timeout to a function so it can be read lazily: the
  -- debounce period is a config value and may change between calls.
  if type(timeout) == 'number' then
    local ms_i = timeout
    timeout = function()
      return ms_i
    end
  end

  ---@type table<any, uv.uv_timer_t?>
  local running = {}
  ---@type table<any, integer?>
  local generation = {}

  ---@param id any
  local function invalidate(id)
    generation[id] = (generation[id] or 0) + 1
    local timer = running[id]
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      running[id] = nil
    end
  end

  ---@return function
  local function debounced(...)
    local id = hash and hash(...) or true
    local argv, argc = { ... }, select('#', ...)

    local timer = running[id]
    if not timer or timer:is_closing() then
      timer = assert(uv.new_timer())
      running[id] = timer
    end

    local gen = generation[id]
    timer:start(assert(timeout()), 0, function()
      vim.schedule(function()
        -- Cancelled between firing and this tick.
        if generation[id] ~= gen then
          return
        end
        -- The handle stays in `running` (fired, therefore stopped) so the next
        -- call can re-arm it; closing it here would close a timer a later call
        -- had already restarted.  `cancel` is what closes it.
        fn(unpack(argv, 1, argc))
      end)
    end)
    return nil
  end

  local function cancel()
    -- `pairs` while mutating: collect the ids first.
    local ids = vim.tbl_keys(running)
    for _, id in ipairs(ids) do
      invalidate(id)
    end
  end

  return debounced, cancel
end

return M
