--- The listener lists: `util.emit` walks a copy of the list, so a listener is
--- free to unsubscribe itself (or add another one) while it is being called.
---
--- See impl/archive/perf/ P2-5: the copy used to be a `vim.deepcopy`,
--- which bought nothing — a fresh table of the same functions is what the walk
--- needs, and functions are copied by reference anyway.
local util = require('vcssign.util')

--- Run a case, then restore the module state it may have changed.
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    if not ok then
      error(err, 0)
    end
  end
end

return {
  {
    name = 'emit calls every listener in order, with the arguments',
    fn = guarded(function()
      local list = {}
      local seen = {}
      for i = 1, 3 do
        list[#list + 1] = function(a, b)
          seen[#seen + 1] = i .. ':' .. a .. b
        end
      end
      util.emit(list, 'x', 'y')
      eq(table.concat(seen, ' '), '1:xy 2:xy 3:xy')
      eq(#list, 3, 'and the list itself is untouched')
    end),
  },
  {
    name = 'a listener that unsubscribes itself does not disturb the walk',
    fn = guarded(function()
      local list = {}
      local seen = {}
      local function second()
        seen[#seen + 1] = 'second'
      end
      local unsubscribe
      unsubscribe = util.subscribe(list, function()
        seen[#seen + 1] = 'first'
        unsubscribe()
      end)
      util.subscribe(list, second)
      util.emit(list)
      eq(table.concat(seen, ' '), 'first second', 'the listener removed mid-walk still ran last')
      eq(#list, 1, 'and it is gone afterwards')
    end),
  },
  {
    name = 'a listener added during the walk is not called this time',
    fn = guarded(function()
      local list = {}
      local seen = {}
      local function late()
        seen[#seen + 1] = 'late'
      end
      util.subscribe(list, function()
        seen[#seen + 1] = 'first'
        util.subscribe(list, late)
      end)
      util.emit(list)
      eq(table.concat(seen, ' '), 'first', 'the walk used its own copy')
      util.emit(list)
      eq(table.concat(seen, ' '), 'first first late', 'and the next emit reaches it')
    end),
  },
}
