--- Extmark signs: the two namespaces, the highlight groups and the placement
--- rules of loop/archive/signs/2026-10-16T23-24-18-line-signs-in-signcolumn.md §3.2 / §4.
---
--- The sign layer is deliberately repository-free: it maps `vcssign.Hunk[]` onto
--- extmarks and knows nothing about git, svn or buffers' contents.  That keeps
--- the placement rules (which hunk goes on which line, which highlight group is
--- used for the number / the whole line) testable with a scratch buffer and no
--- VCS binary, which is what `test/signs_spec.lua` does.
local api = vim.api
local config = require('vcssign.config')

local M = {}

--- Namespace names (§4).  Worktree and index are separate layers so a staged
--- hunk and an unstaged hunk can never fight over one cell (D40).
local NS = {
  worktree = 'vcssign_signs',
  staged = 'vcssign_signs_staged',
}

--- gitsigns' default `sign_priority`.  Deliberately *not* a config key: signs §4
--- lists no `signs.priority`, and the task forbids new keys.
M.PRIORITY = 6

--- Lazily-created namespaces, keyed by layer.  `nvim_create_namespace` is
--- idempotent by name, so this table is only a cache to avoid the call per
--- render.
---@type table<boolean, integer>
M._ns = {}

--- The namespace of one sign layer.
---@param staged? boolean  true for the index layer, false/absent for the worktree
---@return integer ns
function M.namespace(staged)
  local key = staged == true
  local ns = M._ns[key]
  if not ns then
    ns = api.nvim_create_namespace(key and NS.staged or NS.worktree)
    M._ns[key] = ns
  end
  return ns
end

--- 'changedelete' -> 'ChangeDelete'.  The two-word types are spelled out in
--- CamelCase by signs §4 (`VcssignTopDelete` / `VcssignChangeDelete`).
---@type table<string, string>
local CAMEL = {
  add = 'Add',
  change = 'Change',
  delete = 'Delete',
  topdelete = 'TopDelete',
  changedelete = 'ChangeDelete',
  untracked = 'Untracked',
}

--- The highlight group for one (type, layer, kind) triple.
---
---   'add' + staged=false + nil   -> 'VcssignAdd'
---   'add' + staged=false + 'Nr'  -> 'VcssignAddNr'
---   'add' + staged=true  + 'Nr'  -> 'VcssignAddStagedNr'
---
--- The staged suffix form is signs §4's (`VcssignAddStaged`), not gitsigns' prefix
--- form (`GitSignsStagedAdd`).
---@param ty string
---@param staged? boolean
---@param kind? 'Nr'|'Ln'|'Cul'
---@return string
function M.hl_name(ty, staged, kind)
  local name = 'Vcssign' .. (CAMEL[ty] or ty)
  if staged then
    name = name .. 'Staged'
  end
  if kind then
    name = name .. kind
  end
  return name
end

--- The named group each sign type links to.  `changedelete` and `untracked` are
--- links to other `Vcssign*` groups (gitsigns' `GitSignsChange` /
--- `GitSignsAdd` shape), so they must be defined after those exist.
---@type table<string, string>
local BASE_LINK = {
  add = 'DiffAdd',
  change = 'DiffChange',
  delete = 'DiffDelete',
  topdelete = 'DiffDelete',
  changedelete = 'VcssignChange',
  untracked = 'VcssignAdd',
}

--- Theme-provided groups tried, in order, before `BASE_LINK` is used.
---
--- `GitSigns*` is deliberately absent: those names belong to another plugin,
--- and depending on them would make vcssign's colours silently follow a
--- highlight no theme has to provide.  What is left is gitsigns' own fallback
--- chain without that prefix (`highlight.lua:72-83`), and it is tried only
--- because many themes give `DiffAdd` / `DiffChange` / `DiffDelete` a
--- background and *no* foreground: the sign text then falls back to
--- `SignColumn`'s colour instead of a contrasty one.  A theme that defines
--- none of these keeps the pre-chain behaviour exactly, because the last
--- resort is still `BASE_LINK` (`topdelete` reuses the `delete` list).
---@type table<string, string[]>
local FALLBACKS = {
  add = { 'GitGutterAdd', 'SignifySignAdd', 'DiffAddedGutter' },
  change = { 'GitGutterChange', 'SignifySignChange', 'DiffModifiedGutter' },
  delete = { 'GitGutterDelete', 'SignifySignDelete', 'DiffRemovedGutter' },
  changedelete = { 'GitGutterChangeDelete', 'SignifySignChangeDelete' },
  untracked = { 'GitGutterAdd', 'SignifySignAdd', 'DiffAddedGutter' },
}

--- The whole-line (`Ln`) group of each type that has one.  `delete` and
--- `topdelete` are absent on purpose (see `place`): their sign anchors on a
--- line that is still in the buffer, so a whole-line diff highlight would be
--- wrong — gitsigns skips them too (`highlight.lua:34-36`).
---@type table<string, string>
local LN_LINK = {
  add = 'DiffAdd',
  untracked = 'DiffAdd',
  change = 'DiffChange',
  changedelete = 'DiffDelete',
}

--- The order groups are created in, so every `link` target already exists.
local ORDER = { 'add', 'change', 'delete', 'topdelete', 'changedelete', 'untracked' }

--- The staged layer is the *worktree* colour faded toward the background: an
--- already-indexed line should read as "done" instead of competing with the
--- change still sitting in the buffer (signs §4: Staged 用更暗的链接).  Halfway
--- stays legible on both dark and light themes and needs no config key.
local STAGED_FADE = 0.5

--- The attributes a group resolves to, following links.
---@param name string
---@return table
local function resolved(name)
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  return ok and hl or {}
end

--- Does `name` carry a colour, directly or through its link chain?
---
--- The same test gitsigns' `is_hl_set` makes (`highlight.lua:227-236`): a
--- group a theme has only touched with e.g. `bold` is not a usable sign
--- colour, and an undefined group resolves to an empty table.
---@param name string
---@return boolean
local function is_set(name)
  local hl = resolved(name)
  local color = hl.fg
    or hl.bg
    or hl.reverse
    or hl.ctermfg
    or hl.ctermbg
    or (hl.cterm and hl.cterm.reverse)
  return color ~= nil
end

--- The first candidate the theme has actually coloured, or `default` when it
--- has coloured none of them.
---@param candidates string[]
---@param default string
---@return string
local function pick(candidates, default)
  for _, name in ipairs(candidates) do
    if is_set(name) then
      return name
    end
  end
  return default
end

--- `fg` blended toward `bg`; `factor` 1 keeps `fg`, 0 returns `bg`.
---@param fg integer
---@param bg integer
---@param factor number
---@return integer
local function fade(fg, bg, factor)
  local function chan(c, shift)
    return math.floor(c / 2 ^ shift) % 256
  end
  local function mix(shift)
    return math.floor(chan(fg, shift) * factor + chan(bg, shift) * (1 - factor) + 0.5)
  end
  return mix(16) * 65536 + mix(8) * 256 + mix(0)
end

--- Define the staged counterpart of one worktree group.
---
--- Falls back to a plain link when the colours cannot be read (a `cterm`-only
--- theme, or a group with no foreground at all): a *guessed* "dimmer" would be
--- worse than the same colour.
---@param ty string
local function link_staged(ty)
  local name = M.hl_name(ty, true)
  local base = resolved(M.hl_name(ty))
  local normal = resolved('Normal')
  if base.fg and normal.bg then
    api.nvim_set_hl(0, name, { fg = fade(base.fg, normal.bg, STAGED_FADE), default = true })
  else
    api.nvim_set_hl(0, name, { link = M.hl_name(ty), default = true })
  end
end

--- Whether the groups are already defined.
---
--- A flag, not a lookup: `hlexists` reports a *cleared* group as existing
--- (measured on 0.12.4), so it cannot answer "is there work left to do", and
--- reading every group back with `nvim_get_hl` would cost what the definition
--- costs.  What can remove the groups behind our back is a colorscheme, and that
--- is exactly what `ColorScheme` is for: `autocmds.setup` calls back with
--- `force` (perf P2-4).
local defined = false

--- Define every group with `default = true` so a user theme can override, and
--- so calling it after a colorscheme reload is harmless.
---
--- The work (~30 `nvim_set_hl`, plus `nvim_get_hl` on `Normal` and the worktree
--- groups and the fade arithmetic) used to run on every attach — 0.17 ms each
--- time for a set of groups that only a colorscheme change can move (perf P2-4).
---@param force? boolean  define again even though `defined` says otherwise
function M.define_highlights(force)
  if defined and not force then
    return
  end
  defined = true

  local function link(name, target)
    api.nvim_set_hl(0, name, { link = target, default = true })
  end

  -- Plain groups first, then Nr / Ln / Cul, so each link resolves.  The
  -- candidate chain is resolved here, at definition time, against whatever the
  -- theme has defined by now — hence the `ColorScheme` re-run in `autocmds`.
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty), pick(FALLBACKS[ty] or FALLBACKS.delete, BASE_LINK[ty]))
  end
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty, nil, 'Nr'), M.hl_name(ty))
    if LN_LINK[ty] then
      link(M.hl_name(ty, nil, 'Ln'), LN_LINK[ty])
    end
    link(M.hl_name(ty, nil, 'Cul'), M.hl_name(ty))
  end

  -- The staged layer: the same shapes as the worktree layer, one shade closer
  -- to the background (signs §4).  Defined after the plain groups because each
  -- one is derived from its worktree counterpart's resolved colour.
  for _, ty in ipairs(ORDER) do
    link_staged(ty)
  end
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty, true, 'Nr'), M.hl_name(ty, true))
    if LN_LINK[ty] then
      link(M.hl_name(ty, true, 'Ln'), LN_LINK[ty])
    end
    link(M.hl_name(ty, true, 'Cul'), M.hl_name(ty, true))
  end
end

--- The buffer line a hunk's sign hangs on (§3.2).
---
--- This rule is also what `nav` uses to decide where `]c` / `[c` land, so it
--- lives here rather than being spelled out twice: the mark the user sees and
--- the line the cursor jumps to are the same line by construction.
---
--- `add`/`change`/`untracked`/`changedelete` anchor on the hunk's first added
--- line; `delete` hangs on the line *above* the removed block (there is no
--- removed line in the buffer to hold it); `topdelete` is a `delete` at the
--- very top, so it has no line above and hangs on line 1 instead.
---@param h vcssign.Hunk
---@return integer? lnum  1-based, nil for a hunk type with no anchor
function M.sign_line(h)
  local ty = h.type
  if ty == 'delete' then
    return h.removed.start - 1
  end
  if ty == 'topdelete' then
    return 1
  end
  if ty == 'add' or ty == 'change' or ty == 'untracked' or ty == 'changedelete' then
    return h.added.start
  end
  return nil
end

--- How many extmarks a single untracked hunk may write.
---
--- An untracked file is *one* hunk covering every line, and this layer writes
--- one mark per line: a 5000-line new file meant 5000 extmarks (3.8 ms plus the
--- memory that goes with it — perf P2-1).  Past this many lines the block is
--- uniform anyway, so the layer says the same thing ("the whole file is new")
--- with two marks: the first line and the last one.
local UNTRACKED_MARK_LIMIT = 2000

--- Draw `hunks` into one namespace, as a full re-render of that layer.
---
--- The namespace is cleared first: `place` is "this layer's whole picture",
--- so a hunk that disappeared must not leave a stale sign behind.
---@param bufnr integer
---@param hunks vcssign.Hunk[]
---@param opts? { staged?: boolean, priority?: integer }
---@return integer placed  how many extmarks were written
function M.place(bufnr, hunks, opts)
  opts = opts or {}
  local staged = opts.staged == true
  local ns = M.namespace(staged)
  -- One read of the config for the whole placement (perf P2-2: it used to be
  -- eight `config.get()` calls, one per field).
  local conf = config.get()
  -- The staged layer only exists for git, whose `signs_staged` has no
  -- numhl/linehl/culhl of its own; those always come from the worktree set.
  local cs = (staged and conf.signs_staged or conf.signs) or {}
  local show_text = conf.signcolumn
  local numhl = conf.signs.numhl
  local linehl = conf.signs.linehl
  local culhl = conf.signs.culhl
  local priority = opts.priority or M.PRIORITY
  local line_count = api.nvim_buf_line_count(bufnr)

  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- `culhl` is not part of this test: Neovim applies `cursorline_hl_group` to
  -- the sign cell, which does not exist without the text (gitsigns skips the
  -- placement the same way).
  if not show_text and not numhl and not linehl then
    -- `signcolumn = false` and no highlight wanted: nothing this layer drew
    -- could be seen, so the buffer is left without extmarks (gitsigns skips the
    -- placement the same way).
    return 0
  end

  local placed = 0
  ---@param lnum integer  1-based
  ---@param ty string
  local function put(lnum, ty)
    -- A stale hunk can name a line the buffer no longer has (the render runs
    -- after an edit but before the debounced refresh).  Skip it, do not raise.
    if lnum < 1 or lnum > line_count then
      return
    end
    local sign = cs[ty]
    -- `delete`/`topdelete` anchor on a line that is *not* removed, so no `Ln`.
    local want_ln = linehl and ty ~= 'delete' and ty ~= 'topdelete'
    api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
      -- `sign_text = nil` is "no sign", which is what `signcolumn = false`
      -- asks for; the extmark itself is only there for numhl/linehl then.
      sign_text = show_text and ((sign and sign.text) or '?') or nil,
      sign_hl_group = M.hl_name(ty, staged),
      priority = priority,
      number_hl_group = numhl and M.hl_name(ty, staged, 'Nr') or nil,
      line_hl_group = want_ln and M.hl_name(ty, staged, 'Ln') or nil,
      cursorline_hl_group = culhl and M.hl_name(ty, staged, 'Cul') or nil,
    })
    placed = placed + 1
  end

  for _, h in ipairs(hunks or {}) do
    local ty = h.type
    if ty == 'untracked' and h.added.count > UNTRACKED_MARK_LIMIT then
      put(h.added.start, ty)
      put(h.added.start + h.added.count - 1, ty)
    elseif ty == 'add' or ty == 'change' or ty == 'untracked' then
      local n = h.added.count
      for i = 0, n - 1 do
        local line_ty = ty
        -- §3.2: a change that removes more lines than it adds paints its last
        -- added line as `changedelete` (hunk.lua never emits that type).
        if ty == 'change' and i == n - 1 and h.removed.count > h.added.count then
          line_ty = 'changedelete'
        end
        put(h.added.start + i, line_ty)
      end
    elseif ty == 'topdelete' or ty == 'delete' or ty == 'changedelete' then
      -- One sign, placed by the shared rule.  hunk.lua never produces
      -- `changedelete`; an externally built hunk is rendered as a change whose
      -- (single) added line is the changedelete.
      local lnum = M.sign_line(h)
      if lnum then
        put(lnum, ty)
      end
    end
  end
  return placed
end

--- Clear one layer of one buffer.
---@param bufnr integer
---@param staged? boolean  which layer (default worktree)
function M.clear_ns(bufnr, staged)
  api.nvim_buf_clear_namespace(bufnr, M.namespace(staged), 0, -1)
end

--- Clear both layers.
---@param bufnr integer
function M.clear(bufnr)
  M.clear_ns(bufnr, false)
  M.clear_ns(bufnr, true)
end

--- How many signs one layer currently holds.
---@param bufnr integer
---@param staged? boolean
---@return integer
function M.sign_count(bufnr, staged)
  return #api.nvim_buf_get_extmarks(bufnr, M.namespace(staged), 0, -1, {})
end

return M
