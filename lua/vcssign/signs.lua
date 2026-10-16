--- Extmark signs: the two namespaces, the highlight groups and the placement
--- rules of impl/init/07-signs-in-signcolumn.md §3.2 / §4.
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

--- gitsigns' default `sign_priority`.  Deliberately *not* a config key: 07 §4
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
--- CamelCase by 07 §4 (`VcssignTopDelete` / `VcssignChangeDelete`).
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
--- The staged suffix form is 07 §4's (`VcssignAddStaged`), not gitsigns' prefix
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

--- Define every group with `default = true` so a user theme can override, and
--- so calling it twice (or after a colorscheme reload) is harmless.
function M.define_highlights()
  local function link(name, target)
    api.nvim_set_hl(0, name, { link = target, default = true })
  end

  -- Plain groups first, then Nr / Ln / Cul, so each link resolves.
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty), BASE_LINK[ty])
  end
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty, nil, 'Nr'), M.hl_name(ty))
    if LN_LINK[ty] then
      link(M.hl_name(ty, nil, 'Ln'), LN_LINK[ty])
    end
    link(M.hl_name(ty, nil, 'Cul'), M.hl_name(ty))
  end

  -- The staged layer.  "Dimmer" is Step 7's job (it owns the staging layer);
  -- for now each staged group links to its unstaged counterpart (07 §4).
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty, true), M.hl_name(ty))
  end
  for _, ty in ipairs(ORDER) do
    link(M.hl_name(ty, true, 'Nr'), M.hl_name(ty, true))
    if LN_LINK[ty] then
      link(M.hl_name(ty, true, 'Ln'), LN_LINK[ty])
    end
    link(M.hl_name(ty, true, 'Cul'), M.hl_name(ty, true))
  end
end

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
  -- The staged layer only exists for git, whose `signs_staged` has no
  -- numhl/linehl/culhl of its own; those always come from the worktree set.
  local cs = (staged and config.get().signs_staged or config.get().signs) or {}
  local numhl = config.get().signs.numhl
  local linehl = config.get().signs.linehl
  local priority = opts.priority or M.PRIORITY
  local line_count = api.nvim_buf_line_count(bufnr)

  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

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
      sign_text = (sign and sign.text) or '?',
      sign_hl_group = M.hl_name(ty, staged),
      priority = priority,
      number_hl_group = numhl and M.hl_name(ty, staged, 'Nr') or nil,
      line_hl_group = want_ln and M.hl_name(ty, staged, 'Ln') or nil,
    })
    placed = placed + 1
  end

  for _, h in ipairs(hunks or {}) do
    local ty = h.type
    if ty == 'add' or ty == 'change' or ty == 'untracked' then
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
    elseif ty == 'topdelete' then
      -- removed.start == 1 (decided by hunk.lua): there is no line above.
      put(1, 'topdelete')
    elseif ty == 'delete' then
      -- §3.2: the sign hangs on the line *above* the removed block.
      put(h.removed.start - 1, 'delete')
    elseif ty == 'changedelete' then
      -- hunk.lua never produces this; an externally built hunk is rendered as
      -- a change whose (single) added line is the changedelete.
      put(h.added.start, 'changedelete')
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
