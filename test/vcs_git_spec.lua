--- M1 acceptance: git adapter.
--- Covers impl/init/01-vcs-adapter.md §7.3 (linked worktree root detection) and
--- the M6 sign primitives of impl/init/07-signs-in-signcolumn.md §3.1 /
--- §5.2 (baseline text, trackedness, blame, hunk patches, revert).
local helpers = require('helpers')

local git = require('vcssign.vcs.git')

local repo = helpers.fixture('git-repo')
local worktree = helpers.fixture('git-worktree')

--- Scratch repositories, built once per name.
---
--- The shared `temp/git-repo` fixture stays frozen for the root-detection
--- cases; the primitive cases need a repository they can mutate, and
--- `helpers.scratch_dir` wipes a directory the first time it is asked for it.
---@type table<string, string>
local scratch_repos = {}

---@param name string
---@return string dir
local function repo_named(name)
  scratch_repos[name] = scratch_repos[name] or helpers.git_repo(name)
  return scratch_repos[name]
end

--- A repository that has never been committed to: the index exists, HEAD does
--- not (so `<rev>:<rel>` cannot resolve, but `:<rel>` can).
---@param name string
---@return string dir
local function unborn_repo(name)
  local dir = helpers.scratch_dir(name)
  helpers.sh({ 'git', 'init', '-q', '-b', 'main', dir })
  helpers.sh({ 'git', '-C', dir, 'config', 'user.email', 't@t' })
  helpers.sh({ 'git', '-C', dir, 'config', 'user.name', 't' })
  return dir
end

--- A zero-context patch swapping `base` for `patched` in `base.txt`.
local PATCH = '--- a/base.txt\n+++ b/base.txt\n@@ -1 +1 @@\n-base\n+patched\n'

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
    name = 'show reads the index baseline, not the worktree',
    fn = function()
      local dir = repo_named('vcs-git-show')
      helpers.write(dir .. '/base.txt', 'staged\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      helpers.write(dir .. '/base.txt', 'worktree\n')

      local err, text = helpers.wait(function(cb)
        git.show(dir, 'index', 'base.txt', cb)
      end)
      eq(err, nil)
      eq(text, 'staged\n', 'the baseline is what was staged, not what is on disk')

      local herr, head = helpers.wait(function(cb)
        git.show(dir, 'HEAD', 'base.txt', cb)
      end)
      eq(herr, nil)
      eq(head, 'base\n', 'an explicit revision reads its committed blob')

      -- `temp/_spec/vcs-git-unborn` has an index but no commits: `:<rel>` is
      -- readable, `<rev>:<rel>` is not.
      local fresh = unborn_repo('vcs-git-unborn')
      helpers.write(fresh .. '/c.txt', 'first\n')
      helpers.sh({ 'git', '-C', fresh, 'add', 'c.txt' })
      local ierr, itext = helpers.wait(function(cb)
        git.show(fresh, 'index', 'c.txt', cb)
      end)
      eq(ierr, nil)
      eq(itext, 'first\n')
      local uerr, utext = helpers.wait(function(cb)
        git.show(fresh, 'HEAD', 'c.txt', cb)
      end)
      eq(utext, nil, 'HEAD does not resolve before the first commit')
      ok(uerr and uerr:find('invalid object name', 1, true), uerr)
    end,
  },
  {
    name = 'is_tracked answers false instead of erroring, and show says why',
    fn = function()
      local dir = repo_named('vcs-git-tracked')
      helpers.write(dir .. '/u.txt', 'u\n')

      local terr, tracked = helpers.wait(function(cb)
        git.is_tracked(dir, 'base.txt', cb)
      end)
      eq(terr, nil)
      eq(tracked, true)

      -- `git ls-files --error-unmatch` exits 1 for an untracked path; that is an
      -- answer, not a failure.
      local ferr, untracked = helpers.wait(function(cb)
        git.is_tracked(dir, 'u.txt', cb)
      end)
      eq(ferr, nil)
      eq(untracked, false)

      local serr, text = helpers.wait(function(cb)
        git.show(dir, 'index', 'u.txt', cb)
      end)
      eq(text, nil, 'there is no index blob to read')
      ok(serr and serr:find('exists on disk, but not in the index', 1, true), serr)
    end,
  },
  {
    name = 'blame attributes each line and honours a -L window',
    fn = function()
      local dir = repo_named('vcs-git-blame')
      helpers.write(dir .. '/f.txt', 'l1\nl2\nl3\nl4\nl5\nl6\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'f.txt' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'five' })
      helpers.write(dir .. '/f.txt', 'l1\nl2\nl3\nFOUR\nl5\nl6\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'f.txt' })
      helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'four' })
      -- Line 6 is left uncommitted on purpose.
      helpers.write(dir .. '/f.txt', 'l1\nl2\nl3\nFOUR\nl5\nSIX\n')

      local function rev(spec)
        return (helpers.sh({ 'git', '-C', dir, 'rev-parse', spec })):gsub('%s+$', '')
      end
      local five, four = rev('HEAD~1'), rev('HEAD')

      local err, result = helpers.wait(function(cb)
        git.blame(dir, 'f.txt', {}, cb)
      end)
      eq(err, nil)
      eq(result.max_lineno, 6, 'every line of the window is attributed')
      eq(result.lines[1].rev, five)
      eq(result.lines[1].author, 't')
      eq(result.lines[1].summary, 'five')
      eq(type(result.lines[1].time), 'number', 'author-time is unix seconds')
      -- Lines 1-3 are one group; porcelain writes the group size on line 1's
      -- header (four fields) and a three-field header on the lines after it.
      eq(result.lines[2].rev, five)
      eq(result.lines[3].rev, five)
      eq(result.lines[4].rev, four)
      eq(result.lines[4].summary, 'four')
      eq(result.lines[5].rev, five)
      eq(result.lines[6].rev, string.rep('0', 40), 'an uncommitted line has no commit')
      eq(result.lines[6].author, 'Not Committed Yet')

      -- `-L` returns only the requested window; the map stays sparse and the
      -- keys are still the file's own line numbers (what Step 11 keys on).
      local werr, window = helpers.wait(function(cb)
        git.blame(dir, 'f.txt', { from = 3, to = 5 }, cb)
      end)
      eq(werr, nil)
      eq(window.max_lineno, 5)
      eq(window.lines[1], nil)
      eq(window.lines[2], nil)
      eq(window.lines[3].rev, five)
      eq(window.lines[4].rev, four)
      eq(window.lines[5].rev, five)
      eq(window.lines[6], nil)
    end,
  },
  {
    name = 'apply_patch --cached writes the index, and reverse takes it back',
    fn = function()
      local dir = repo_named('vcs-git-patch-index')

      local err = helpers.wait(function(cb)
        git.apply_patch(dir, PATCH, { cached = true }, cb)
      end)
      eq(err, nil)
      eq(helpers.sh({ 'git', '-C', dir, 'show', ':base.txt' }), 'patched\n')
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' }, 'the worktree is untouched')

      local rerr = helpers.wait(function(cb)
        git.apply_patch(dir, PATCH, { cached = true, reverse = true }, cb)
      end)
      eq(rerr, nil)
      eq(helpers.sh({ 'git', '-C', dir, 'show', ':base.txt' }), 'base\n')
    end,
  },
  {
    name = 'apply_patch changes the worktree, and reverse restores it',
    fn = function()
      local dir = repo_named('vcs-git-patch-worktree')

      local err = helpers.wait(function(cb)
        git.apply_patch(dir, PATCH, {}, cb)
      end)
      eq(err, nil)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'patched' })
      eq(helpers.sh({ 'git', '-C', dir, 'show', ':base.txt' }), 'base\n', 'the index is untouched')

      local rerr = helpers.wait(function(cb)
        git.apply_patch(dir, PATCH, { reverse = true }, cb)
      end)
      eq(rerr, nil)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' })
    end,
  },
  {
    name = 'apply_patch refuses a patch that does not end in a newline',
    fn = function()
      local dir = repo_named('vcs-git-patch-eol')
      -- The patch arrives on stdin as one string; git needs the final `\n` to
      -- tell the last line from a truncated stream (B4 in 07 §8).
      local err = helpers.wait(function(cb)
        git.apply_patch(dir, PATCH:sub(1, -2), {}, cb)
      end)
      ok(err, 'a truncated patch must not be applied silently')
      ok(err:find('corrupt patch', 1, true), 'git says why: ' .. err)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' }, 'nothing was applied')
    end,
  },
  {
    name = 'revert restores the worktree from the index',
    fn = function()
      local dir = repo_named('vcs-git-revert')
      helpers.write(dir .. '/base.txt', 'changed\n')
      helpers.sh({ 'git', '-C', dir, 'add', 'base.txt' })
      helpers.write(dir .. '/base.txt', 'changed again\n')

      local err = helpers.wait(function(cb)
        git.revert(dir, 'base.txt', cb)
      end)
      eq(err, nil)
      -- The index holds `changed`, HEAD holds `base`: revert is the index.
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'changed' })
    end,
  },
}
