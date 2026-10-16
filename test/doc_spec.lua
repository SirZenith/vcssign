--- Documentation spec: the help file and the code have to agree.
---
--- `doc/vcssign.txt` is hand written (M5, 05 §5) — there is no generator — so
--- nothing but a test stops it from drifting away from `config.lua`,
--- `cli.lua` and `renderer.lua`.  Each case pins one of those links.
---
--- No external binaries: this spec runs everywhere `renderer_spec` does.
local config = require('vcssign.config')
local renderer = require('vcssign.sidebar.renderer')
local status_type = require('vcssign.status_type')

local cli = require('vcssign.cli')
local helpers = require('helpers')

local M = {}

local doc_path = vim.fs.joinpath(helpers.plugin_root, 'doc', 'vcssign.txt')

--- The help file, as lines (erroring loudly if it vanished).
---@return string[] lines
local function doc_lines()
  local lines = vim.fn.readfile(doc_path)
  if #lines == 0 then
    error('doc/vcssign.txt is empty or missing: ' .. doc_path, 2)
  end
  return lines
end

--- The whole help text as one string (tag / key searches are substring checks).
---@return string text
local function doc_text()
  return table.concat(doc_lines(), '\n')
end

--- Does `needle` appear in the help text?
---@param needle string
---@return boolean
local function mentions(needle)
  return doc_text():find(needle, 1, true) ~= nil
end

--- Assert that every name in `names` is documented, reporting all the misses at
--- once (one failure per case beats one failure per name).
---@param names string[]
---@param what string
local function all_documented(names, what)
  local missing = {}
  for _, name in ipairs(names) do
    if not mentions(name) then
      missing[#missing + 1] = name
    end
  end
  eq(missing, {}, string.format('every %s is documented', what))
end

--- Tags as written in the help file, in order of appearance.
---@return string[]
local function tags_in_file()
  local found, seen = {}, {}
  for _, line in ipairs(doc_lines()) do
    for tag in line:gmatch('%*([%w%-_%.]+)%*') do
      if not seen[tag] then
        seen[tag] = true
        found[#found + 1] = tag
      end
    end
  end
  return found
end

M[#M + 1] = {
  name = 'the help file is a well formed, LF-only vim help file',
  fn = function()
    local lines = doc_lines()
    ok(lines[1]:find('*vcssign.txt*', 1, true) == 1, 'the first line carries the file tag')
    ok(lines[#lines]:find('ft=help', 1, true) ~= nil, 'the last line is a help modeline')
    for i, line in ipairs(lines) do
      ok(not line:find('\r', 1, true), string.format('line %d has no CR (help files are LF)', i))
    end
  end,
}

M[#M + 1] = {
  name = 'every documented tag is unique and :helptags accepts the file',
  fn = function()
    local tags = tags_in_file()
    ok(#tags > 10, 'the file declares its section tags, got ' .. #tags)
    local scratch = helpers.scratch_dir('doc-helptags')
    vim.fn.mkdir(scratch, 'p')
    vim.fn.writefile(doc_lines(), vim.fs.joinpath(scratch, 'vcssign.txt'))
    -- `:helptags` fails loudly on a duplicate tag, which is the point here.
    vim.cmd('helptags ' .. vim.fn.fnameescape(scratch))
    -- tags(1) lines are `<name><TAB><file><TAB><search>`: compare the first
    -- field, because the name in column one has no tab in front of it.
    local indexed = {}
    for _, line in ipairs(vim.fn.readfile(vim.fs.joinpath(scratch, 'tags'))) do
      local name = line:match('^([^\t]*)\t')
      if name then
        indexed[name] = true
      end
    end
    ok(vim.tbl_count(indexed) >= #tags, 'helptags saw every tag')
    for _, tag in ipairs(tags) do
      ok(indexed[tag], ':helptags indexed ' .. tag)
    end
  end,
}

M[#M + 1] = {
  name = 'every configuration key is documented, defaults included',
  fn = function()
    local keys = vim.tbl_keys(config.defaults)
    table.sort(keys)
    all_documented(keys, 'configuration key')
    -- The section names, not just the top level key: a user reads the doc for
    -- `sidebar.width`, not for `sidebar`.
    all_documented({
      'sidebar.position',
      'sidebar.width',
      'sidebar.group_by',
      'sidebar.keymaps',
      'diff.mode',
      'commit.message_input',
    }, 'nested option')
    for _, key in ipairs({ 'left', 'right', 'float', 'vertical', 'input' }) do
      ok(mentions(key), string.format('the value %q the config accepts is documented', key))
    end
  end,
}

M[#M + 1] = {
  name = 'every :Vcssign subcommand is documented',
  fn = function()
    all_documented(cli.subcommands, 'subcommand')
    ok(mentions(':Vcssign'), 'the command itself is documented')
  end,
}

M[#M + 1] = {
  name = 'every default keymap action is documented',
  fn = function()
    local actions = {}
    for _, action in pairs(config.defaults.sidebar.keymaps) do
      if type(action) == 'string' and not vim.tbl_contains(actions, action) then
        actions[#actions + 1] = action
      end
    end
    table.sort(actions)
    all_documented(actions, 'keymap action')
  end,
}

M[#M + 1] = {
  name = 'every status, symbol and highlight group is documented',
  fn = function()
    all_documented(vim.tbl_keys(status_type.default_symbol), 'status')
    all_documented(vim.tbl_keys(renderer.highlights), 'highlight group')
    all_documented(vim.tbl_keys(status_type.default_sign_hl_group), 'sign highlight group')
  end,
}

M[#M + 1] = {
  name = 'the public API surface is documented',
  fn = function()
    all_documented({
      'setup',
      'open',
      'close',
      'toggle',
      'refresh',
      'get_status',
      'get_entries',
    }, 'API function')
    ok(mentions('vcssign://'), 'the sidebar buffer name scheme is documented')
  end,
}

return M
