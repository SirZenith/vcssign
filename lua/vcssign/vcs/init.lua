--- VCS system registry and repository detection.
---
--- Adding a VCS means writing one module against the `vcssign.VcsSystem`
--- interface and adding it to `MODULES`/`config.systems` — no layer above this
--- one changes.  See impl/knowledge/vcs/ §6.
local config = require('vcssign.config')

local M = {}

---@type table<string, string>  system name -> module path
M.MODULES = {
  git = 'vcssign.vcs.git',
  svn = 'vcssign.vcs.svn',
}

---@param name string
---@return vcssign.VcsSystem?
function M.get(name)
  local path = M.MODULES[name]
  if not path then
    return nil
  end
  local ok, system = pcall(require, path)
  if not ok then
    vim.notify(
      string.format('vcssign: failed to load VCS system %q: %s', name, system),
      vim.log.levels.ERROR
    )
    return nil
  end
  return system
end

--- Enabled systems, in the priority order given by `config.systems`.
---@return vcssign.VcsSystem[]
function M.get_systems()
  local systems = {}
  for _, name in ipairs(config.get().systems or {}) do
    local system = M.get(name)
    if system then
      systems[#systems + 1] = system
    end
  end
  return systems
end

---@class vcssign.Detection
---@field system vcssign.VcsSystem
---@field root string?  marker-scan result (the async value is authoritative)
---@field get_root_async fun(cb: fun(err: string?, root: string?))

--- Detect which VCS owns `path`, using the cheap marker scan only.
---
--- When several systems claim the same path (a git repo containing an svn
--- working copy, say), the deepest root wins, because that is the one actually
--- containing the file.
---@param path string
---@return vcssign.Detection?
function M.detect(path)
  ---@type vcssign.Detection?
  local best
  local best_len = -1
  for _, system in ipairs(M.get_systems()) do
    local root = system.find_root_sync(path)
    if root and #root > best_len then
      best_len = #root
      best = {
        system = system,
        root = root,
        get_root_async = function(cb)
          system.get_root_async(path, cb)
        end,
      }
    end
  end
  return best
end

--- Failures that mean "the VCS has definitely answered: this is not a
--- repository".  Any other failure (a missing binary, dubious ownership, a
--- timeout) is transient or environmental, and there the marker scan is a
--- better answer than nothing.
local NOT_A_REPO = {
  'not a git repository',
  'not a working copy',
  'e155007',
  -- svn prints this one as a *warning* (W155007) on some builds, and the
  -- repository manager wraps an empty detection in its own words.
  'w155007',
  'no repository',
}

---@param err string?
---@return boolean
local function is_definitive_negative(err)
  if type(err) ~= 'string' then
    return false
  end
  local lower = err:lower()
  for _, needle in ipairs(NOT_A_REPO) do
    if lower:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Is this failure the VCS itself saying "there is no repository here"?
---
--- Any other failure (a missing binary, dubious ownership, a timeout) is
--- environmental, and the command layer reports it as an error rather than as
--- "no repository here" — which is why it is shared rather than re-listed per
--- caller.
---@param err string?
---@return boolean
M.is_definitive_negative = is_definitive_negative

--- Detect and resolve the authoritative root.
---
--- The marker scan decides *which* system owns the path; that system's own
--- command then supplies the root (it knows about worktrees and linked
--- working copies).  If the marker scan came up empty, every system is probed
--- in priority order, so a repository whose marker directory was removed or
--- hidden is still found.
---@param path string
---@param cb fun(err: string?, system: vcssign.VcsSystem?, root: string?)
function M.detect_async(path, cb)
  local detection = M.detect(path)
  if detection then
    return detection.get_root_async(function(err, root)
      if root then
        return cb(nil, detection.system, root)
      end
      -- The command failed.  A marker whose repository the VCS itself rejects
      -- (stale `.git` file, deleted worktree) must not be resurrected here.
      if detection.root and not is_definitive_negative(err) then
        return cb(nil, detection.system, detection.root)
      end
      cb(err, nil, nil)
    end)
  end

  local systems = M.get_systems()
  local function step(i, last_err)
    if i > #systems then
      return cb(last_err, nil, nil)
    end
    systems[i].get_root_async(path, function(err, root)
      if root then
        return cb(nil, systems[i], root)
      end
      step(i + 1, err or last_err)
    end)
  end
  step(1, nil)
end

return M
