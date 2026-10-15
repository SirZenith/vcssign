--- Unified VCS status enum + presentation defaults (symbol / highlight / priority).
---
--- Both the git and svn adapters normalise their native status characters into
--- this single vocabulary, so every layer above (renderer, actions) is
--- VCS-agnostic.  See impl/init/01-vcs-adapter.md §2.
local M = {}

--- The VCS-agnostic status vocabulary.
---@enum vcssign.StatusType
M.StatusType = {
  modified = 'modified',
  added = 'added',
  deleted = 'deleted',
  renamed = 'renamed',
  untracked = 'untracked',
  ignored = 'ignored',
  typechange = 'typechange', -- git: T
  conflicted = 'conflicted', -- git: U/AA/DD, svn: C
  replaced = 'replaced', -- svn only: R
  missing = 'missing', -- svn only: !
  switched = 'switched', -- svn only: S (5th column)
  external = 'external', -- svn only: X
  obstructed = 'obstructed', -- svn only: ~
}

--- A single file's status, split into the two "domains" every supported VCS has.
---
--- Field naming follows git's own porcelain terminology: `index` is the X
--- column (staged), `worktree` is the Y column.  `local` would have been the
--- plan's name for the Y column, but it is a Lua keyword and therefore not
--- dot-accessible.  Either field may be nil: a staged-only change has no
--- worktree status, an untracked file has no index status, and svn has no index
--- domain at all.
---@class vcssign.FileStatus
---@field index vcssign.StatusType?    git X column (staged area); always nil for svn
---@field worktree vcssign.StatusType? git Y column / svn status column 1
---@field orig_path string?            rename/copy source, relative to the repo root

--- Default single-character symbol per status.
---@type table<vcssign.StatusType, string>
M.default_symbol = {
  modified = 'M',
  added = 'A',
  deleted = 'D',
  renamed = 'R',
  untracked = 'U',
  ignored = 'I',
  typechange = 'T',
  conflicted = '!',
  replaced = 'R',
  missing = '!',
  switched = 'S',
  external = 'X',
  obstructed = '~',
}

--- Default highlight group for the sign column.
---@type table<vcssign.StatusType, string>
M.default_sign_hl_group = {
  modified = 'VcssignSignModified',
  added = 'VcssignSignAdded',
  deleted = 'VcssignSignDeleted',
  renamed = 'VcssignSignRenamed',
  untracked = 'VcssignSignUntracked',
  ignored = 'VcssignSignIgnored',
  typechange = 'VcssignSignModified',
  conflicted = 'VcssignSignConflicted',
  replaced = 'VcssignSignModified',
  missing = 'VcssignSignConflicted',
  switched = 'VcssignSignModified',
  external = 'VcssignSignIgnored',
  obstructed = 'VcssignSignConflicted',
}

--- Default highlight group for inline text (used by the sidebar renderer).
---@type table<vcssign.StatusType, string>
M.default_hl_group = {
  modified = 'VcssignModified',
  added = 'VcssignAdded',
  deleted = 'VcssignDeleted',
  renamed = 'VcssignRenamed',
  untracked = 'VcssignUntracked',
  ignored = 'VcssignIgnored',
  typechange = 'VcssignModified',
  conflicted = 'VcssignConflicted',
  replaced = 'VcssignModified',
  missing = 'VcssignConflicted',
  switched = 'VcssignModified',
  external = 'VcssignIgnored',
  obstructed = 'VcssignConflicted',
}

--- Higher wins when the sign column is too narrow to show both domains.
---@type table<vcssign.StatusType, integer>
M.default_sign_priority = {
  conflicted = 100,
  missing = 90,
  modified = 50,
  typechange = 50,
  replaced = 50,
  deleted = 40,
  renamed = 40,
  added = 30,
  untracked = 20,
  obstructed = 15,
  switched = 10,
  external = 5,
  ignored = 1,
}

--- 'modified' -> 'Modified' (highlight group naming helper).
---@param status string
---@return string
function M.camel(status)
  return (status:gsub('^%l', string.upper))
end

---@param status vcssign.StatusType?
---@return string symbol single character
function M.symbol(status)
  return (status and M.default_symbol[status]) or '?'
end

---@param status vcssign.StatusType?
---@return string hl_group
function M.sign_hl_group(status)
  return (status and M.default_sign_hl_group[status]) or 'VcssignSignUnknown'
end

---@param status vcssign.StatusType?
---@return string hl_group
function M.hl_group(status)
  return (status and M.default_hl_group[status]) or 'VcssignUnknown'
end

---@param status vcssign.StatusType?
---@return integer priority
function M.sign_priority(status)
  return (status and M.default_sign_priority[status]) or 0
end

return M
