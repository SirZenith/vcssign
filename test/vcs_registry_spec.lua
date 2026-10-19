--- M1 acceptance: the system registry and repository detection.
--- Covers impl/knowledge/vcs/ §7.4 (nested repositories switch system
--- based on the path), the probing fallback, and the `config.systems` ordering.
local helpers = require('helpers')

local config = require('vcssign.config')
local registry = require('vcssign.vcs')

local nested = helpers.fixture('nested')
local inner = helpers.fixture('nested/inner')

--- `registry.MODULES` and `config` are module-level singletons, so state churn
--- has to be undone even when an assertion fails.
---@param fn fun()
local function with_isolated_state(fn)
  local modules = registry.MODULES
  local systems = vim.deepcopy(config.get().systems)
  local ok, err = pcall(fn)
  registry.MODULES = modules
  config.setup({ systems = systems })
  if not ok then
    error(err, 2)
  end
end

--- Register a stub system under a throwaway name.
---@param name string
---@param sync_root string?   what the (cheap) marker scan finds
---@param async_root string?  what the (authoritative) command finds
---@param async_err string?   what the command reports when it finds nothing
local function register_stub(name, sync_root, async_root, async_err)
  package.loaded['vcssign_spec_stub_' .. name] = {
    name = name,
    keyfile = '.stub',
    capabilities = {},
    find_root_sync = function()
      return sync_root
    end,
    get_root_async = function(_, cb)
      cb(async_err, async_root)
    end,
  }
  registry.MODULES = vim.tbl_extend('force', registry.MODULES, {
    [name] = 'vcssign_spec_stub_' .. name,
  })
end

return {
  {
    name = 'detect picks the system whose root contains the path',
    fn = function()
      local outer = registry.detect(nested .. '/top.txt')
      ok(outer, 'the outer git repository must be detected')
      eq(outer.system.name, 'git')
      eq(outer.root, nested)

      local inner_detection = registry.detect(inner .. '/base.txt')
      ok(inner_detection, 'the inner svn working copy must be detected')
      eq(inner_detection.system.name, 'svn')
      eq(inner_detection.root, inner)
    end,
  },
  {
    name = 'detect_async resolves the authoritative root of the deepest system',
    fn = function()
      local err, system, root = helpers.wait(function(cb)
        registry.detect_async(inner .. '/base.txt', cb)
      end)
      eq(err, nil)
      eq(system.name, 'svn')
      eq(root, inner)

      local outer_err, outer_system, outer_root = helpers.wait(function(cb)
        registry.detect_async(nested .. '/top.txt', cb)
      end)
      eq(outer_err, nil)
      eq(outer_system.name, 'git')
      eq(outer_root, nested)
    end,
  },
  {
    name = 'detect_async prefers the command answer over the marker answer',
    fn = function()
      with_isolated_state(function()
        register_stub('disagree', '/marker/root', '/command/root', nil)
        config.setup({ systems = { 'disagree' } })
        local err, system, root = helpers.wait(function(cb)
          registry.detect_async('/some/file.txt', cb)
        end)
        eq(err, nil)
        eq(system.name, 'disagree')
        eq(root, '/command/root')
      end)
    end,
  },
  {
    name = 'detect_async probes every system when no marker is found',
    fn = function()
      with_isolated_state(function()
        register_stub('miss1', nil, nil, 'miss1: nope')
        register_stub('hit2', nil, '/found/only/by/command', nil)
        config.setup({ systems = { 'miss1', 'hit2' } })
        local err, system, root = helpers.wait(function(cb)
          registry.detect_async('/some/file.txt', cb)
        end)
        eq(err, nil)
        eq(system.name, 'hit2', 'the marker-less scan must fall through to the command probe')
        eq(root, '/found/only/by/command')
      end)
    end,
  },
  {
    name = 'detect_async reports the last error when nothing matches',
    fn = function()
      with_isolated_state(function()
        register_stub('miss1', nil, nil, 'miss1: nope')
        register_stub('miss2', nil, nil, 'miss2: also nope')
        config.setup({ systems = { 'miss1', 'miss2' } })
        local err, system, root = helpers.wait(function(cb)
          registry.detect_async('/some/file.txt', cb)
        end)
        eq(err, 'miss2: also nope')
        eq(system, nil)
        eq(root, nil)
      end)
    end,
  },
  {
    name = 'detect_async does not resurrect a marker the VCS itself rejects',
    fn = function()
      -- A `.git` file pointing at a gitdir that does not exist (worktree whose
      -- main repository is gone) must not become a repository root.
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, 'p')
      vim.fn.writefile({ 'gitdir: ' .. dir .. '/gone' }, vim.fs.joinpath(dir, '.git'))
      local err, system, root = helpers.wait(function(cb)
        registry.detect_async(dir .. '/f.txt', cb)
      end)
      vim.fn.delete(dir, 'rf')
      ok(err, 'expected the git error to be reported')
      eq(system, nil)
      eq(root, nil)
    end,
  },
  {
    name = 'detect returns nothing outside a repository',
    fn = function()
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, 'p')
      local detection = registry.detect(dir)
      vim.fn.delete(dir, 'rf')
      eq(detection, nil)
    end,
  },
  {
    name = 'config.systems controls which systems are enabled, in order',
    fn = function()
      with_isolated_state(function()
        local original = vim.deepcopy(config.get().systems)
        config.setup({ systems = { 'svn' } })
        local systems = registry.get_systems()
        eq(#systems, 1)
        eq(systems[1].name, 'svn')
        config.setup({ systems = original })
        eq(#registry.get_systems(), #original, 'restored')
        eq(registry.get_systems()[1].name, original[1])
      end)
    end,
  },
}
