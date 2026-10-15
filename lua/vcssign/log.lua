--- Level-gated diagnostics.
---
--- Every message is routed through `vim.notify` on the main loop, because most
--- of the interesting ones originate in a libuv callback, which runs in a fast
--- event context where no vim API may be touched (verified: both `uv_timer_t`
--- and `uv_fs_event_t` callbacks report `vim.in_fast_event() == true`).
local config = require('vcssign.config')

local M = {}

---@alias vcssign.LogLevel 'debug'|'info'|'warn'|'error'

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

local NOTIFY_LEVEL = {
  debug = vim.log.levels.DEBUG,
  info = vim.log.levels.INFO,
  warn = vim.log.levels.WARN,
  error = vim.log.levels.ERROR,
}

---@param level vcssign.LogLevel
---@return boolean
function M.enabled(level)
  local threshold = LEVELS[config.get().log_level] or LEVELS.warn
  return threshold <= (LEVELS[level] or LEVELS.warn)
end

---@param level vcssign.LogLevel
---@param ... any  message, or a `string.format` template plus its arguments
local function emit(level, ...)
  if not M.enabled(level) then
    return
  end
  local argc = select('#', ...)
  local msg = argc == 1 and tostring((...)) or string.format(...)
  vim.schedule(function()
    vim.notify('vcssign: ' .. msg, NOTIFY_LEVEL[level])
  end)
end

---@param ... any
function M.debug(...)
  emit('debug', ...)
end

---@param ... any
function M.info(...)
  emit('info', ...)
end

---@param ... any
function M.warn(...)
  emit('warn', ...)
end

---@param ... any
function M.error(...)
  emit('error', ...)
end

return M
