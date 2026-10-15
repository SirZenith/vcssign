--- Minimal headless test runner.
---
---   nvim --headless -u NONE -l test/run.lua [spec ...]
---   scripts/run_tests.sh [spec ...]
---
--- Prints TAP-ish lines and exits non-zero when anything failed, so CI can use
--- it as-is.  `make_test_repos.sh` must have been run first (temp/ fixtures).
--- See impl/init/05-testing-infra.md §3.
--- `vim.fs.normalize` is lexical and does not absolutise, but `-l test/run.lua`
--- hands us a relative script path.  Same rule as `vcssign.vcs.base.normalize`.
---@param path string
---@return string
local function abspath(path)
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

local source = abspath(debug.getinfo(1, 'S').source:sub(2))
local test_dir = vim.fs.dirname(source)
local root = vim.fs.dirname(test_dir)

-- Resolve `require('vcssign...')` (lua/) and `require('helpers')` (test/)
-- without depending on the current directory or on a user config.
package.path = table.concat({
  root .. '/lua/?.lua',
  root .. '/lua/?/init.lua',
  test_dir .. '/?.lua',
}, ';') .. ';' .. package.path

local helpers = require('helpers')

--- TAP lines go to stdout *explicitly*: neovim's `print` writes to stderr in
--- headless mode, where a result line can be glued to a `vim.notify` from the
--- plugin under test (observed: two `ok` lines joined into one), and where a
--- `2>/dev/null` in CI would swallow the results entirely.
---@param msg string
local function say(msg)
  io.stdout:write(msg, '\n')
end

_G.ok = helpers.ok
_G.eq = helpers.eq
_G.check = helpers.ok

--- Specs and the external binaries they need; skipped when one is missing.
local REQUIRES = {
  exec_spec = { 'git' },
  vcs_git_spec = { 'git' },
  vcs_svn_spec = { 'svn' },
  vcs_registry_spec = { 'git', 'svn' },
  repo_spec = { 'git', 'svn' },
  sidebar_spec = { 'git', 'svn' },
  autocmds_spec = { 'git', 'svn' },
  actions_spec = { 'git', 'svn', 'svnadmin' },
}

local DEFAULT_SPECS = {
  'status_type_spec',
  'config_spec',
  'exec_spec',
  'vcs_git_spec',
  'vcs_svn_spec',
  'vcs_registry_spec',
  'repo_spec',
  'renderer_spec',
  'sidebar_spec',
  'autocmds_spec',
  'actions_spec',
}

local requested = {}
for _, name in ipairs(arg or {}) do
  if name ~= '' and name:sub(1, 1) ~= '-' and not name:match('run%.lua$') then
    requested[#requested + 1] = name
  end
end
if #requested == 0 then
  requested = DEFAULT_SPECS
end

if vim.uv.fs_stat(vim.fs.joinpath(root, 'temp')) == nil then
  io.stderr:write('fixtures missing: run scripts/make_test_repos.sh first\n')
  vim.cmd('cq')
end

local total, failed = 0, 0
for _, spec_name in ipairs(requested) do
  local missing = nil
  for _, binary in ipairs(REQUIRES[spec_name] or {}) do
    if vim.fn.executable(binary) ~= 1 then
      missing = binary
      break
    end
  end
  if missing then
    say(string.format('# SKIP %s (%s not found)', spec_name, missing))
  else
    local loaded, spec = pcall(require, spec_name)
    if not loaded then
      total, failed = total + 1, failed + 1
      say(string.format('not ok %d - %s: failed to load', total, spec_name))
      say('  ' .. tostring(spec):gsub('\n', '\n  '))
    else
      for _, case in ipairs(spec) do
        total = total + 1
        local ran, err = pcall(case.fn)
        if ran then
          say(string.format('ok %d - %s: %s', total, spec_name, case.name))
        else
          failed = failed + 1
          say(string.format('not ok %d - %s: %s', total, spec_name, case.name))
          say('  ' .. tostring(err):gsub('\n', '\n  '))
        end
      end
    end
  end
end

say(string.format('1..%d', total))
say(string.format('=== %d tests, %d failed ===', total, failed))
io.stdout:flush()
-- Scratch repositories created by repo_spec are throwaway by design.
helpers.cleanup()
if failed > 0 then
  vim.cmd('cq')
end
