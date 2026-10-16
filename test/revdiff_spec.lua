--- M6 Step 11: the diff view — `:Vcssign diff`, `diffthis` and
--- `diffthis_rev` (`hd` / `hD`).
---
--- `diffthis` with no revision *is* the `diff` action (the configured
--- baseline), so the interesting half is the arbitrary revision: the text is
--- built by `vcssign.revdiff` from `show(root, rev, rel)` and the buffer, which
--- is why one case checks the built text directly and the rest run it against a
--- real repository.
local api = vim.api

local actions = require('vcssign.actions')
local attach = require('vcssign.attach')
local config = require('vcssign.config')
local manager = require('vcssign.repo_manager')
local revdiff = require('vcssign.revdiff')

local helpers = require('helpers')

--- Buffers a case opened, so it can close them again (in `guarded`).
---@type table<integer, true>
local touched = {}

--- Close what a case touched, then reset the module state and the config.
---@param fn function
---@return function
local function guarded(fn)
  return function()
    local ok, err = pcall(fn)
    for bufnr in pairs(touched) do
      pcall(api.nvim_buf_delete, bufnr, { force = true })
    end
    touched = {}
    for _, bufnr in ipairs(api.nvim_list_bufs()) do
      if api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'diff' then
        pcall(api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    attach.forget_all()
    manager.dispose_all()
    config.setup({})
    if not ok then
      error(err, 0)
    end
  end
end

--- A buffer showing `path`, attached and rendered.
---@param path string
---@return integer bufnr
local function open_attached(path)
  vim.cmd('edit ' .. vim.fn.fnameescape(path))
  local bufnr = api.nvim_get_current_buf()
  touched[bufnr] = true
  attach.attach(bufnr)
  helpers.wait_for(function()
    local st = attach.state(bufnr)
    return st ~= nil and st.attached and st.buf_text ~= nil
  end, 'the buffer to attach')
  return bufnr
end

--- The lines of the diff view, or nil when no diff is on screen.
---@return string[]?
local function diff_lines()
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == 'diff' then
      if api.nvim_buf_get_name(bufnr):find('^vcssign://') then
        return api.nvim_buf_get_lines(bufnr, 0, -1, false)
      end
    end
  end
  return nil
end

--- Whether the diff view holds `line` (an exact `+…`/`-…` line).
---@param line string
---@return boolean
local function diff_has(line)
  for _, l in ipairs(diff_lines() or {}) do
    if l == line then
      return true
    end
  end
  return false
end

--- Run `fn` with `vim.ui.input` answering `value`.
---@param value string|nil
---@param fn fun()
local function with_input(value, fn)
  local real = vim.ui.input
  vim.ui.input = function(_, on_confirm)
    on_confirm(value)
  end
  local ok, err = pcall(fn)
  vim.ui.input = real
  if not ok then
    error(err, 0)
  end
end

--- A repository whose `base.txt` is committed as `alpha\nbeta\n` and then
--- edited in place to `ALPHA\nbeta\n`.
---@param name string
---@return string dir
local function edited_repo(name)
  local dir = helpers.git_repo(name)
  helpers.write(dir .. '/base.txt', 'alpha\nbeta\n')
  helpers.sh({ 'git', '-C', dir, 'add', '-A' })
  helpers.sh({ 'git', '-C', dir, 'commit', '-qm', 'two lines' })
  helpers.write(dir .. '/base.txt', 'ALPHA\nbeta\n')
  return dir
end

return {
  {
    name = 'a whole-file diff announces the file once and then lists its hunks',
    fn = guarded(function() --[[ no repository needed ]]
      local text = revdiff.text('base.txt', 'one\ntwo\nthree\nfour\n', {
        'ONE',
        'two',
        'three',
        'FOUR',
      })
      eq(select(2, text:gsub('diff %-%-git a/base%.txt b/base%.txt', '')), 1, 'one file header')
      eq(select(2, text:gsub('@@ ', '@@ ')), 2, 'one block per hunk')
      ok(text:find('\n-one\n', 1, true), 'the removed line is there')
      ok(text:find('\n+FOUR\n', 1, true), 'and the added one')

      eq(revdiff.text('base.txt', 'same\n', { 'same' }), '', 'no change, no diff')
    end),
  },
  {
    name = 'diffthis without a revision is the configured-baseline diff',
    fn = guarded(function()
      local dir = helpers.git_repo('revdiff-baseline')
      helpers.write(dir .. '/base.txt', 'base\nLINE TWO\n')
      open_attached(dir .. '/base.txt')
      helpers.sh({ 'git', '-C', dir, 'add', '-A' }, dir)

      actions.diffthis(nil)
      helpers.wait_for(function()
        return diff_lines() ~= nil
      end, 'the diff window')
      ok(diff_has('+LINE TWO'), 'the staged change is what is shown')
    end),
  },
  {
    name = 'diffthis <rev> compares the buffer with that revision',
    fn = guarded(function()
      local dir = edited_repo('revdiff-head')
      local bufnr = open_attached(dir .. '/base.txt')
      eq(attach.hunks(bufnr)[1].added.start, 1)

      actions.diffthis(nil, { rev = 'HEAD' })
      helpers.wait_for(function()
        return diff_lines() ~= nil
      end, 'the diff window')
      ok(diff_has('-alpha'), 'the committed line is the baseline')
      ok(diff_has('+ALPHA'), 'and the buffer is what changed')
    end),
  },
  {
    name = 'diffthis <rev> says so when that revision matches the buffer',
    fn = guarded(function()
      -- `base.txt` is committed and untouched here: the buffer *is* `HEAD`.
      local dir = helpers.git_repo('revdiff-same')
      open_attached(dir .. '/base.txt')

      local seen = helpers.capture_notify(function()
        actions.diffthis(nil, { rev = 'HEAD' })
      end, function(s)
        return #s > 0
      end)
      eq(seen[1].message, 'vcssign: base.txt: no changes against HEAD')
      eq(diff_lines(), nil, 'and no window is opened')
    end),
  },
  {
    name = 'diffthis_rev asks which revision before it shows anything',
    fn = guarded(function()
      local dir = edited_repo('revdiff-ask')
      open_attached(dir .. '/base.txt')

      with_input('HEAD', function()
        actions.diffthis_rev(nil)
        helpers.wait_for(function()
          return diff_lines() ~= nil
        end, 'the diff window')
      end)
      ok(diff_has('-alpha'), 'the typed revision is the baseline')

      -- Cancelling the prompt shows nothing at all.
      local seen = helpers.capture_notify(function()
        with_input(nil, function()
          actions.diffthis_rev(nil)
        end)
      end)
      eq(#seen, 0)
    end),
  },
  {
    name = 'a rev diff needs the file in a buffer, and says so',
    fn = guarded(function()
      local dir = edited_repo('revdiff-nobuffer')
      helpers.with_repo('spec-revdiff', dir, function()
        local seen = helpers.capture_notify(function()
          actions.diffthis(dir .. '/base.txt', { rev = 'HEAD' })
        end, function(s)
          return #s > 0
        end)
        eq(seen[1].level, vim.log.levels.ERROR)
        ok(seen[1].message:find('is not open in a buffer', 1, true), seen[1].message)
        eq(diff_lines(), nil, 'nothing is opened')
      end)
    end),
  },
  {
    name = 'svn compares with a revision through the same view',
    fn = guarded(function()
      local dir = helpers.svn_checkout('revdiff-svn')
      helpers.write(dir .. '/base.txt', 'changed\n')
      open_attached(dir .. '/base.txt')

      actions.diffthis(nil, { rev = 'HEAD' })
      helpers.wait_for(function()
        return diff_lines() ~= nil
      end, 'the diff window')
      ok(diff_has('-base'), 'the committed revision is the baseline')
      ok(diff_has('+changed'), 'and the worktree is what changed')
    end),
  },
}
