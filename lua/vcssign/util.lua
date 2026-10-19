--- Small helpers shared by the runtime layers.
local log = require('vcssign.log')

local M = {}

---@param path string
---@return boolean
function M.is_dir(path)
  local stat = vim.uv.fs_stat(path)
  return stat ~= nil and stat.type == 'directory'
end

--- Register a listener and hand back a function that removes it again.
---@param list function[]
---@param fn function
---@return fun() unsubscribe
function M.subscribe(list, fn)
  list[#list + 1] = fn
  return function()
    for i, f in ipairs(list) do
      if f == fn then
        table.remove(list, i)
        return
      end
    end
  end
end

--- Call every subscriber, isolating failures: a broken UI listener must not be
--- able to stop the refresh pipeline or take an unrelated command down with it.
---@param list function[]
---@param ... any
function M.emit(list, ...)
  if #list == 0 then
    return
  end
  -- Copy first: a listener is allowed to unsubscribe itself while being called.
  -- A shallow copy is what the job needs — the list is a fresh table of the same
  -- functions, and functions are copied by reference anyway, so `vim.deepcopy`
  -- bought nothing but two table allocations per emit (perf P2-5).
  local current = {}
  for i, fn in ipairs(list) do
    current[i] = fn
  end
  for _, fn in ipairs(current) do
    local ok, err = pcall(fn, ...)
    if not ok then
      log.error('subscriber failed: %s', tostring(err))
    end
  end
end

return M
