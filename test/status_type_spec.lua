--- M1: invariants of the shared status vocabulary.
--- See impl/init/01-vcs-adapter.md §2.
local st = require('vcssign.status_type')

return {
  {
    name = 'every status has a symbol, highlight groups and a sign priority',
    fn = function()
      for name, value in pairs(st.StatusType) do
        eq(name, value, 'enum keys mirror their values')
        ok(st.default_symbol[value], 'missing symbol for ' .. value)
        eq(#st.default_symbol[value], 1, 'sign_text must be one character wide: ' .. value)
        ok(st.default_sign_hl_group[value], 'missing sign highlight group for ' .. value)
        ok(st.default_hl_group[value], 'missing highlight group for ' .. value)
        eq(type(st.default_sign_priority[value]), 'number', 'missing sign priority for ' .. value)
      end
    end,
  },
  {
    name = 'unknown statuses fall back instead of erroring',
    fn = function()
      eq(st.symbol(nil), '?')
      eq(st.sign_hl_group('nonexistent'), 'VcssignSignUnknown')
      eq(st.hl_group(nil), 'VcssignUnknown')
      eq(st.sign_priority(nil), 0)
    end,
  },
  {
    name = 'highlight group names follow the Vcssign<Camel> convention',
    fn = function()
      eq(st.sign_hl_group('modified'), 'VcssignSignModified')
      eq(st.hl_group('untracked'), 'VcssignUntracked')
      eq(st.camel('typechange'), 'Typechange')
    end,
  },
  {
    name = 'conflicts outrank every other status in the sign column',
    fn = function()
      for name in pairs(st.StatusType) do
        if name ~= 'conflicted' then
          ok(
            st.default_sign_priority.conflicted > st.default_sign_priority[name],
            'conflicted must outrank ' .. name
          )
        end
      end
    end,
  },
}
