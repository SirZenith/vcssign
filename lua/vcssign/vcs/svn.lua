--- svn adapter.
---
--- See impl/init/01-vcs-adapter.md §5.  Everything here was verified against a
--- real working copy (svn 1.14.5 on Windows), which is why the parser is
--- column-based rather than whitespace-based:
---   * paths are printed verbatim (spaces, UTF-8 bytes, no quoting), so only a
---     fixed column offset can separate status from path;
---   * Windows working copies print backslashes and CRLF line endings;
---   * tree conflict victims get a *continuation* line right after them, and a
---     worktree with any conflict prints a `Summary of conflicts:` trailer.
---     Neither starts with a recognised status column, which is exactly why the
---     parser drops anything it does not understand instead of pattern-matching
---     for what it expects.
---
--- svn has no index, so every entry carries only a worktree status.
local exec = require('vcssign.exec')
local base = require('vcssign.vcs.base')

local M = {}

M.name = 'svn'
M.keyfile = '.svn'
M.capabilities = {
  stage = false, -- svn has no staging area
  unstage = false,
  commit = true,
  diff = true,
}

local SVN = { 'svn', '--non-interactive' }

---@param args string[]
---@return string[]
local function build(args)
  local cmd = vim.deepcopy(SVN)
  vim.list_extend(cmd, args)
  return cmd
end

-- ▏ root detection ───────────────────────────────────────────────────────────

---@param dir string
---@return string?
local function marker_at(dir)
  local stat = vim.uv.fs_stat(vim.fs.joinpath(dir, '.svn'))
  return stat and stat.type == 'directory' and dir or nil
end

---@param path string
---@return string?
function M.find_root_sync(path)
  return base.find_root_upwards(path, marker_at)
end

---@type boolean
local warned_no_show_item = false

--- `svn info --show-item wc-root` needs svn >= 1.9.  When the option is
--- unsupported we degrade to the (already computed) marker-scan result rather
--- than failing, and say so once.
---@param path string
---@param cb fun(err: string?, root: string?)
function M.get_root_async(path, cb)
  exec.run(
    build({ 'info', '--show-item', 'wc-root' }),
    { cwd = base.dirname_of(path) },
    function(err, res)
      if not err then
        local root = exec.split_lines(res.stdout)[1]
        if root and root ~= '' then
          return cb(nil, base.normalize(root))
        end
        err = 'svn: empty wc-root output'
      end
      if err:lower():match('invalid option') or err:lower():match('unknown option') then
        if not warned_no_show_item then
          warned_no_show_item = true
          vim.notify(
            'vcssign: this svn does not support --show-item (< 1.9); using the marker scan for root detection',
            vim.log.levels.WARN
          )
        end
        return cb(nil, M.find_root_sync(path))
      end
      cb(err)
    end
  )
end

-- ▏ status ───────────────────────────────────────────────────────────────────

--- First status column: the item's own state.
---
--- `X` (an externals definition) and `I` (ignored) never appear today: the
--- status command passes `--ignore-externals` and nothing asks svn for
--- ignored files.  Both are kept so changing the command line later needs
--- no parser change.
local ITEM_MAP = {
  A = 'added',
  C = 'conflicted',
  D = 'deleted',
  I = 'ignored',
  M = 'modified',
  R = 'replaced',
  X = 'external',
  ['?'] = 'untracked',
  ['!'] = 'missing',
  ['~'] = 'obstructed',
}

--- Parse one `svn status` line.  Layout (from `svn help status`):
---   1 item · 2 properties · 3 locked · 4 history · 5 switched/external ·
---   6 repo lock · 7 tree conflict, then one space, then the path at column 9.
---
--- Anything that does not look like a status line yields nil: the explanation
--- lines following a tree conflict, the `Summary of conflicts:` trailer, and the
--- `Status against revision:` line (when svn decides to print it).
---@param line string
---@param root string
---@return vcssign.StatusEntry?
function M.parse_line(line, root)
  -- Tree conflict explanations and any other continuation output.
  if line:match('^%s*>') or #line < 9 then
    return nil
  end
  local cols = line:sub(1, 7)
  local item, prop, switched, tree = cols:sub(1, 1), cols:sub(2, 2), cols:sub(5, 5), cols:sub(7, 7)

  ---@type vcssign.StatusType?
  local status
  if tree == 'C' or prop == 'C' then
    -- A conflict is the most severe thing that can be said about a file.
    status = 'conflicted'
  elseif item == ' ' then
    status = prop == 'M' and 'modified' or nil
  else
    status = ITEM_MAP[item]
  end
  if not status and switched == 'S' then
    status = 'switched'
  end
  if not status and switched == 'X' then
    -- Column 5 `X`: a versioned file created by an externals definition.
    status = 'external'
  end
  if not status then
    return nil
  end

  local rel = line:sub(9)
  if rel == '' then
    return nil
  end
  -- Windows working copies report `sub\deeper\file.txt`; on POSIX a backslash is
  -- an ordinary file name character, so the conversion must stay platform-local.
  if exec.is_windows then
    rel = rel:gsub('\\', '/')
  end
  return base.make_entry(root, rel, { worktree = status })
end

---@param stdout string
---@param root string
---@return vcssign.StatusEntry[]
function M.parse_status(stdout, root)
  local entries = {}
  for _, line in ipairs(exec.split_lines(stdout)) do
    local entry = M.parse_line(line, root)
    if entry then
      entries[#entries + 1] = entry
    end
  end
  return entries
end

---@param root string
---@param cb fun(err: string?, entries: vcssign.StatusEntry[]?)
function M.status(root, cb)
  exec.run(build({ 'status', '--ignore-externals' }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    local ok, entries = pcall(M.parse_status, res.stdout, root)
    if not ok then
      return cb('svn: failed to parse status output: ' .. tostring(entries))
    end
    cb(nil, entries)
  end)
end

-- ▏ actions ──────────────────────────────────────────────────────────────────

M.stage = base.unsupported('stage')
M.unstage = base.unsupported('unstage')

---@param root string
---@param files string[]
---@param msg string
---@param cb fun(err: string?, info: string?)
function M.commit(root, files, msg, cb)
  if #files == 0 then
    return cb('svn: refusing to commit an empty file list')
  end
  exec.run(build({ 'commit', '-m', msg, '--' }, files), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    -- stdout is a progress list (`Sending   base.txt` ...); the useful summary
    -- line is the revision.  Fall back to the first line for other svn builds.
    local stdout = (res and res.stdout) or ''
    cb(nil, stdout:match('Committed revision %d+') or exec.first_line(stdout))
  end)
end

---@param root string
---@param file string  path relative to `root`
---@param _opts table   unused: svn has no index to diff against
---@param cb fun(err: string?, text: string?)
function M.diff(root, file, _opts, cb)
  exec.run(build({ 'diff', '--', file }), { cwd = root }, function(err, res)
    if err then
      return cb(err)
    end
    cb(nil, res.stdout)
  end)
end

return M
