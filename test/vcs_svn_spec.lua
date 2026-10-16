--- M1 acceptance: svn adapter.
--- Covers impl/init/01-vcs-adapter.md §7.2 (`wc-root` detection) and §7.5
--- (capability errors), plus the M6 sign primitives of
--- impl/init/07-signs-in-signcolumn.md §3.1 / §5.3.
local helpers = require('helpers')

local svn = require('vcssign.vcs.svn')

local repo = helpers.fixture('svn-repo')

--- Scratch working copies, built once per name (a fresh server each time).
--- The shared `temp/svn-server` fixture is only read.
---@type table<string, string>
local scratch_repos = {}

---@param name string
---@return string dir  working copy
local function repo_named(name)
  if not scratch_repos[name] then
    scratch_repos[name] = helpers.svn_repo(name)
  end
  return scratch_repos[name]
end

--- A zero-context patch in the dialect `svn patch --strip 0` accepts: bare
--- filenames, no `a/`+`b/` prefixes (see the strip case below).
local BARE_PATCH = '--- base.txt\n+++ base.txt\n@@ -1 +1 @@\n-base\n+patched\n'

return {
  {
    name = 'capabilities advertise no staging area, but the sign primitives',
    fn = function()
      eq(svn.capabilities.stage, false)
      eq(svn.capabilities.staged_signs, false)
      eq(svn.capabilities.revert_hunk, true)
      eq(svn.capabilities.blame, true)
      eq(svn.capabilities.show_rev, true)
      eq(svn.capabilities.commit, true)
    end,
  },
  {
    name = 'find_root_sync resolves a file path to its working copy root',
    fn = function()
      eq(svn.find_root_sync(repo .. '/base.txt'), repo)
      eq(svn.find_root_sync(repo .. '/sub2/q.txt'), repo)
    end,
  },
  {
    name = 'get_root_async uses svn info --show-item wc-root',
    fn = function()
      local err, root = helpers.wait(function(cb)
        svn.get_root_async(repo .. '/sub2', cb)
      end)
      eq(err, nil)
      eq(root, repo)
    end,
  },
  {
    name = 'get_root_async reports a clean error outside a working copy',
    fn = function()
      local err = helpers.wait(function(cb)
        svn.get_root_async(helpers.plugin_root .. '/lua', cb)
      end)
      ok(err ~= nil, 'expected an error for a non-working-copy path')
    end,
  },
  {
    name = 'unsupported capabilities fail with an error, not a crash',
    fn = function()
      local stage_err = helpers.wait(function(cb)
        svn.stage(repo, { 'base.txt' }, cb)
      end)
      ok(stage_err and stage_err:match('capability unsupported'), 'stage must report unsupported')
      local unstage_err = helpers.wait(function(cb)
        svn.unstage(repo, { 'base.txt' }, cb)
      end)
      ok(
        unstage_err and unstage_err:match('capability unsupported'),
        'unstage must report unsupported'
      )
    end,
  },
  {
    name = 'diff returns the unified diff of a modified file',
    fn = function()
      local err, text = helpers.wait(function(cb)
        svn.diff(repo, 'base.txt', {}, cb)
      end)
      eq(err, nil)
      ok(text:match('Index: base%.txt'), 'expected a unified diff header')
      ok(text:match('%+mod'), 'expected the worktree content in the diff')
    end,
  },
  {
    name = "show reads BASE for 'index', an explicit revision, and refuses the unmanaged",
    fn = function()
      local dir = repo_named('vcs-svn-show')
      local err, base = helpers.wait(function(cb)
        svn.show(dir, 'index', 'base.txt', cb)
      end)
      eq(err, nil)
      eq(base, 'base\n', "'index' is svn's BASE (D42)")

      -- Move BASE forward, so 'index' and revision 1 can be told apart.
      helpers.write(dir .. '/base.txt', 'second\n')
      helpers.sh({ 'svn', 'commit', '-q', '-m', 'second', dir .. '/base.txt' })
      local berr, head = helpers.wait(function(cb)
        svn.show(dir, 'index', 'base.txt', cb)
      end)
      eq(berr, nil)
      eq(head, 'second\n', 'BASE follows the last commit')
      local rerr, first = helpers.wait(function(cb)
        svn.show(dir, '1', 'base.txt', cb)
      end)
      eq(rerr, nil)
      eq(first, 'base\n', 'an explicit revision reads that revision')

      helpers.write(dir .. '/u.txt', 'u\n')
      local uerr, utext = helpers.wait(function(cb)
        svn.show(dir, 'index', 'u.txt', cb)
      end)
      eq(utext, nil, 'there is no BASE blob to read')
      ok(uerr and uerr:find('is not under version control', 1, true), uerr)
    end,
  },
  {
    name = 'is_tracked answers true for BASE files and false for unversioned ones',
    fn = function()
      local dir = repo_named('vcs-svn-tracked')
      helpers.write(dir .. '/u.txt', 'u\n')

      local terr, tracked = helpers.wait(function(cb)
        svn.is_tracked(dir, 'base.txt', cb)
      end)
      eq(terr, nil)
      eq(tracked, true)

      local ferr, untracked = helpers.wait(function(cb)
        svn.is_tracked(dir, 'u.txt', cb)
      end)
      eq(ferr, nil)
      eq(untracked, false)
    end,
  },
  {
    name = 'is_tracked reports a path that does not exist as untracked',
    fn = function()
      local dir = repo_named('vcs-svn-tracked')

      -- A missing path produces *no* `svn status` output (exit 0), so the
      -- decision has to come from `svn info`'s exit code.
      local nerr, missing = helpers.wait(function(cb)
        svn.is_tracked(dir, 'nope.txt', cb)
      end)
      eq(nerr, nil, 'a missing path is an answer, not an error')
      eq(missing, false)
    end,
  },
  {
    name = 'blame reads revisions and authors out of the xml, marking local edits',
    fn = function()
      local dir = repo_named('vcs-svn-blame')
      helpers.write(dir .. '/base.txt', 'a\nb\nc\n')
      helpers.sh({ 'svn', 'commit', '-q', '-m', 'three', dir .. '/base.txt' })
      local author = (helpers.sh({ 'svn', 'info', '--show-item', 'last-changed-author', dir })):gsub(
        '%s+$',
        ''
      )
      -- Line 2 is only in the working copy: `svn blame` reports no commit for it.
      helpers.write(dir .. '/base.txt', 'a\nB\nc\n')

      local err, result = helpers.wait(function(cb)
        svn.blame(dir, 'base.txt', {}, cb)
      end)
      eq(err, nil)
      eq(result.max_lineno, 3)
      eq(result.lines[1].rev, '2', 'the revision the line came from')
      eq(result.lines[1].author, author)
      eq(result.lines[2].rev, '-', 'a locally modified line has no revision')
      eq(result.lines[2].author, '-')
      eq(result.lines[3].rev, '2')
      ok(author ~= '' and author ~= '-', 'the working copy has a real author')
    end,
  },
  {
    name = 'apply_patch applies, reverses, and only accepts the strip-0 dialect',
    fn = function()
      local dir = repo_named('vcs-svn-patch')

      local err = helpers.wait(function(cb)
        svn.apply_patch(dir, BARE_PATCH, {}, cb)
      end)
      eq(err, nil)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'patched' })
      ok(
        helpers.sh({ 'svn', 'diff', dir .. '/base.txt' }):find('+patched', 1, true),
        'svn agrees the working copy changed'
      )

      -- Dropping a hunk is the reverse patch (D41).
      local rerr = helpers.wait(function(cb)
        svn.apply_patch(dir, BARE_PATCH, { reverse = true }, cb)
      end)
      eq(rerr, nil)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' })
      eq(helpers.sh({ 'svn', 'diff', dir .. '/base.txt' }), '', 'and is clean again')

      -- Measured boundary (§5.3 said otherwise): at `--strip 0` a `git diff`
      -- header keeps its `a/`+`b/` components and the hunk is rejected.  The
      -- patch a caller writes therefore must not carry them.
      local git_style = '--- a/base.txt\n+++ b/base.txt\n@@ -1 +1 @@\n-base\n+patched\n'
      local gerr = helpers.wait(function(cb)
        svn.apply_patch(dir, git_style, {}, cb)
      end)
      ok(gerr and gerr:find('did not apply cleanly', 1, true), gerr)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' }, 'nothing was applied')
    end,
  },
  {
    name = 'apply_patch reports a rejected hunk and removes its temporary file',
    fn = function()
      local dir = repo_named('vcs-svn-patch-conflict')
      helpers.write(dir .. '/base.txt', 'something else\n')

      -- svn exits 0 on a conflict, so the adapter has to read stdout; and the
      -- patch file it wrote (svn 1.14.5 refuses stdin) is its to remove.
      local tempnames = {}
      local real_tempname = vim.fn.tempname
      vim.fn.tempname = function()
        local path = real_tempname()
        tempnames[#tempnames + 1] = path
        return path
      end
      local callok, callerr = pcall(function()
        local err = helpers.wait(function(cb)
          svn.apply_patch(dir, BARE_PATCH, {}, cb)
        end)
        ok(err ~= nil, 'a hunk that cannot apply must be reported, not silently dropped')
        ok(err:find('did not apply cleanly', 1, true), err)
      end)
      vim.fn.tempname = real_tempname
      if not callok then
        error(callerr, 0)
      end

      ok(#tempnames >= 1, 'the patch must have gone through a temporary file')
      for _, path in ipairs(tempnames) do
        eq(vim.uv.fs_stat(path), nil, 'the temporary patch file must be removed: ' .. path)
      end
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'something else' }, 'the file is untouched')
    end,
  },
  {
    name = 'revert throws the working copy back to BASE',
    fn = function()
      local dir = repo_named('vcs-svn-revert')
      helpers.write(dir .. '/base.txt', 'changed\n')

      local err = helpers.wait(function(cb)
        svn.revert(dir, 'base.txt', cb)
      end)
      eq(err, nil)
      eq(vim.fn.readfile(dir .. '/base.txt'), { 'base' })
      eq(helpers.sh({ 'svn', 'diff', dir .. '/base.txt' }), '', 'and svn agrees it is clean')
    end,
  },
}
