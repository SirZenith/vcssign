--- M1 acceptance: git adapter.
--- Covers impl/init/01-vcs-adapter.md §7.1 (status matrix, `-z` parsing) and
--- §7.3 (linked worktree root detection).
local helpers = require('helpers')

local git = require('vcssign.vcs.git')

local repo = helpers.fixture('git-repo')
local conflict_repo = helpers.fixture('git-repo-conflict')
local worktree = helpers.fixture('git-worktree')

--- `temp/git-repo` as prepared by scripts/make_test_repos.sh.
local EXPECTED_REPO = {
  'base.txt:-/modified',
  'new.txt:-/untracked',
  'old.txt:-/deleted',
  'renamed.txt:renamed/-',
  'staged-add.txt:added/-',
  'staged-mod.txt:added/modified',
  'sub/x.txt:added/-',
  'untracked 名 .txt:-/untracked',
}

--- Status of the whole fixture (blocking).
---@return vcssign.StatusEntry[]
local function fixture_status()
  local err, entries = helpers.wait(function(cb)
    git.status(repo, cb)
  end)
  eq(err, nil)
  return entries
end

return {
  {
    name = 'find_root_sync resolves a file path to its repository root',
    fn = function()
      eq(git.find_root_sync(repo .. '/base.txt'), repo)
    end,
  },
  {
    name = 'find_root_sync walks up from nested and non-existent paths',
    fn = function()
      eq(git.find_root_sync(repo .. '/sub/x.txt'), repo)
      eq(git.find_root_sync(repo .. '/no/such/dir/file.txt'), repo)
    end,
  },
  {
    name = 'find_root_sync recognises a linked worktree, where .git is a file',
    fn = function()
      eq(git.find_root_sync(worktree), worktree)
    end,
  },
  {
    name = 'find_root_sync returns nil outside a repository',
    fn = function()
      -- Assumes the OS temp directory is not itself inside a repository.
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, 'p')
      local root = git.find_root_sync(dir)
      vim.fn.delete(dir, 'rf')
      eq(root, nil)
    end,
  },
  {
    name = 'find_root_sync does not trust a stale git marker',
    fn = function()
      local dir = vim.fs.normalize(vim.fn.tempname())
      vim.fn.mkdir(dir, 'p')

      -- An empty .git directory is debris, not a repository.
      vim.fn.mkdir(vim.fs.joinpath(dir, '.git'), 'p')
      eq(git.find_root_sync(dir), nil)

      -- A .git file whose gitdir points nowhere is debris too (a worktree whose
      -- main repository is gone).
      vim.fn.delete(vim.fs.joinpath(dir, '.git'), 'rf')
      vim.fn.writefile(
        { 'gitdir: ' .. vim.fs.joinpath(dir, 'missing-gitdir') },
        vim.fs.joinpath(dir, '.git')
      )
      eq(git.find_root_sync(dir), nil)

      vim.fn.delete(dir, 'rf')
    end,
  },
  {
    name = 'get_root_async asks git for an authoritative root',
    fn = function()
      local err, root = helpers.wait(function(cb)
        git.get_root_async(repo .. '/sub', cb)
      end)
      eq(err, nil)
      eq(root, repo)
    end,
  },
  {
    name = 'get_root_async resolves a worktree root',
    fn = function()
      local err, root = helpers.wait(function(cb)
        git.get_root_async(worktree .. '/base.txt', cb)
      end)
      eq(err, nil)
      eq(root, worktree)
    end,
  },
  {
    name = 'status reports the whole fixture matrix',
    fn = function()
      eq(helpers.status_set(fixture_status()), EXPECTED_REPO)
    end,
  },
  {
    name = 'status reports absolute, root-anchored paths',
    fn = function()
      for _, entry in ipairs(fixture_status()) do
        eq(entry.path, vim.fs.joinpath(repo, entry.rel_path), 'path of ' .. entry.rel_path)
        ok(
          not entry.rel_path:match('^[/\\]') and not entry.rel_path:match('^%a:[/\\]'),
          'rel_path must be relative to the root: ' .. entry.rel_path
        )
      end
    end,
  },
  {
    name = 'status keeps the rename source in orig_path',
    fn = function()
      local renamed = helpers.entry(fixture_status(), 'renamed.txt')
      ok(renamed, 'renamed.txt must be reported')
      eq(renamed.status.orig_path, '文件 名.txt')
    end,
  },
  {
    name = 'status reports conflicts as conflicted on both domains',
    fn = function()
      local err, entries = helpers.wait(function(cb)
        git.status(conflict_repo, cb)
      end)
      eq(err, nil)
      eq(helpers.status_set(entries), { 'conflict.txt:conflicted/conflicted' })
    end,
  },
  {
    name = 'status works inside a linked worktree',
    fn = function()
      local err, entries = helpers.wait(function(cb)
        git.status(worktree, cb)
      end)
      eq(err, nil)
      eq(helpers.status_set(entries), {}, 'a fresh worktree is clean')
    end,
  },
  {
    name = 'parse_status consumes the two records of a rename entry',
    fn = function()
      -- Exactly the byte stream `git status --porcelain=v1 -z` produced for the
      -- fixture: NUL separated, rename = new path then original path.
      local payload = table.concat({
        ' M base.txt',
        'R  renamed.txt',
        '文件 名.txt',
        '?? untracked 名 .txt',
        '',
      }, '\0')
      local entries = git.parse_status(payload, repo)
      eq(helpers.status_set(entries), {
        'base.txt:-/modified',
        'renamed.txt:renamed/-',
        'untracked 名 .txt:-/untracked',
      })
      eq(helpers.entry(entries, 'renamed.txt').status.orig_path, '文件 名.txt')
    end,
  },
  {
    name = 'parse_status tolerates a rename record with a missing source',
    fn = function()
      local entries = git.parse_status('R  only.txt', repo)
      eq(#entries, 1)
      eq(entries[1].status.orig_path, nil)
    end,
  },
  {
    name = 'parse_status maps unstaged, staged and unmerged columns',
    fn = function()
      local payload = table.concat({
        ' M worktree-only.txt',
        'M  index-only.txt',
        'MM both.txt',
        'UU unmerged.txt',
        'AA both-added.txt',
        'T  typechange.txt',
        '!! ignored.txt',
        '',
      }, '\0')
      eq(helpers.status_set(git.parse_status(payload, repo)), {
        'both-added.txt:conflicted/conflicted',
        'both.txt:modified/modified',
        'ignored.txt:-/ignored',
        'index-only.txt:modified/-',
        'typechange.txt:typechange/-',
        'unmerged.txt:conflicted/conflicted',
        'worktree-only.txt:-/modified',
      })
    end,
  },
  {
    name = 'status enters a subdirectory path without doubling the root',
    fn = function()
      local entry = helpers.entry(fixture_status(), 'sub/x.txt')
      ok(entry, 'sub/x.txt must be reported')
      eq(entry.path, repo .. '/sub/x.txt')
    end,
  },
}
