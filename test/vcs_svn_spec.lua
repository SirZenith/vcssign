--- M1 acceptance: svn adapter.
--- Covers impl/init/01-vcs-adapter.md §7.2 (status matrix, fixed-column parsing,
--- `wc-root` detection) and §7.5 (capability errors).
local helpers = require('helpers')

local svn = require('vcssign.vcs.svn')

local repo = helpers.fixture('svn-repo')
local conflict_repo = helpers.fixture('svn-conflict-a')
local switch_repo = helpers.fixture('svn-switch')

--- `temp/svn-repo` as prepared by scripts/make_test_repos.sh:
--- MM (content+property), ! missing, ? unversioned (incl. a space + UTF-8 name),
--- D, A, R replaced, plus an added directory with a file in it.
local EXPECTED_REPO = {
  'base.txt:-/modified',
  'missing.txt:-/missing',
  'new.txt:-/untracked',
  'old.txt:-/deleted',
  'prop.txt:-/added',
  'repl.txt:-/replaced',
  'sp ace 名.txt:-/untracked',
  'sub2:-/added',
  'sub2/q.txt:-/added',
}

--- Build an svn status line: seven status columns, one space, then the path.
---@param columns string  exactly 7 characters
---@param path string
---@return string
local function status_line(columns, path)
  assert(#columns == 7, 'a status line has exactly 7 status columns')
  return columns .. ' ' .. path
end

---@return vcssign.StatusEntry[]
local function fixture_status()
  local err, entries = helpers.wait(function(cb)
    svn.status(repo, cb)
  end)
  eq(err, nil)
  return entries
end

return {
  {
    name = 'capabilities advertise no staging area',
    fn = function()
      eq(svn.capabilities.stage, false)
      eq(svn.capabilities.unstage, false)
      eq(svn.capabilities.commit, true)
      eq(svn.capabilities.diff, true)
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
    name = 'status reports the whole fixture matrix',
    fn = function()
      eq(helpers.status_set(fixture_status()), EXPECTED_REPO)
    end,
  },
  {
    name = 'status anchors paths at the working copy root, not at the cwd',
    fn = function()
      -- Regression guard: `svn status <target>` prints paths relative to the
      -- *cwd*, which is what the vcs-helper.nvim reference got wrong.
      for _, entry in ipairs(fixture_status()) do
        eq(entry.path, vim.fs.joinpath(repo, entry.rel_path), 'path of ' .. entry.rel_path)
        eq(
          entry.rel_path:match('^temp[/\\]'),
          nil,
          'rel_path must not be anchored at the process cwd: ' .. entry.rel_path
        )
      end
    end,
  },
  {
    name = 'status converts Windows backslashes to "/"',
    fn = function()
      local entry = helpers.entry(fixture_status(), 'sub2/q.txt')
      ok(entry, 'sub2/q.txt must be reported')
      eq(entry.path, repo .. '/sub2/q.txt')
    end,
  },
  {
    name = 'parse_line maps the first column to the status vocabulary',
    fn = function()
      local cases = {
        { status_line('M      ', 'a.txt'), 'modified' },
        { status_line('A      ', 'a.txt'), 'added' },
        { status_line('D      ', 'a.txt'), 'deleted' },
        { status_line('R      ', 'a.txt'), 'replaced' },
        { status_line('C      ', 'a.txt'), 'conflicted' },
        { status_line('?      ', 'a.txt'), 'untracked' },
        { status_line('!      ', 'a.txt'), 'missing' },
        { status_line('I      ', 'a.txt'), 'ignored' },
        { status_line('X      ', 'a.txt'), 'external' },
        { status_line('~      ', 'a.txt'), 'obstructed' },
        { status_line('    S  ', 'a.txt'), 'switched' },
      }
      for _, case in ipairs(cases) do
        local entry = svn.parse_line(case[1], repo)
        ok(entry, 'expected an entry for: ' .. case[1])
        eq(entry.status.worktree, case[2], 'status of: ' .. case[1])
        eq(entry.status.index, nil, 'svn never reports an index status')
      end
    end,
  },
  {
    name = 'parse_line treats a property-only change as modified',
    fn = function()
      local entry = svn.parse_line(status_line(' M     ', 'prop.txt'), repo)
      ok(entry, 'property modifications must be reported')
      eq(entry.status.worktree, 'modified')
    end,
  },
  {
    name = 'parse_line treats a tree conflict as conflicted',
    fn = function()
      local entry = svn.parse_line(status_line('      C', 'tree.txt'), repo)
      ok(entry, 'tree conflict victims must be reported')
      eq(entry.status.worktree, 'conflicted')
    end,
  },
  {
    name = 'parse_line skips conflict explanations and status summaries',
    fn = function()
      eq(svn.parse_line('      >   local edit, incoming delete upon update', repo), nil)
      eq(svn.parse_line('Status against revision:  5', repo), nil)
      eq(svn.parse_line('', repo), nil)
    end,
  },
  {
    name = 'parse_line keeps spaces and non-ASCII bytes in the path',
    fn = function()
      local entry = svn.parse_line(status_line('?      ', 'sp ace 名.txt'), repo)
      ok(entry, 'the path must be read from column 9, not split on whitespace')
      eq(entry.rel_path, 'sp ace 名.txt')
      eq(entry.path, repo .. '/sp ace 名.txt')
    end,
  },
  {
    name = 'parse_status tolerates CRLF line endings',
    fn = function()
      local entries = svn.parse_status(status_line('M      ', 'crlf.txt') .. '\r\n', repo)
      eq(#entries, 1)
      eq(entries[1].rel_path, 'crlf.txt')
    end,
  },
  {
    name = 'parse_status strips a lone trailing CR',
    fn = function()
      local entries = svn.parse_status(status_line('M      ', 'cr.txt') .. '\r', repo)
      eq(#entries, 1)
      eq(entries[1].rel_path, 'cr.txt')
    end,
  },
  {
    name = 'status reports a real tree conflict from column 7',
    fn = function()
      -- `temp/svn-conflict-a` was built by editing a file locally that another
      -- working copy deleted upstream.  svn then prints column 7 = C, an
      -- explanation line starting with '>' and a "Summary of conflicts:"
      -- trailer; only the file itself may survive parsing.
      local err, entries = helpers.wait(function(cb)
        svn.status(conflict_repo, cb)
      end)
      eq(err, nil)
      eq(helpers.status_set(entries), { 'f.txt:-/conflicted' })
    end,
  },
  {
    name = 'status reports a switched subdirectory from column 5',
    fn = function()
      local err, entries = helpers.wait(function(cb)
        svn.status(switch_repo, cb)
      end)
      eq(err, nil)
      eq(helpers.status_set(entries), { 'sub:-/switched' })
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
}
