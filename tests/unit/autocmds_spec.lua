local assert = require('luassert')
local stub = require('luassert.stub')
local state = require('opencode.state')
local autocmds = require('opencode.ui.autocmds')
local ui = require('opencode.ui.ui')

describe('panel autocmd subscriptions', function()
  local original_windows
  local windows
  local teardown
  local original_code_buf
  local original_code_win
  local created_tabs
  local created_wins
  local created_bufs

  local function handlers(group)
    local ok, result = pcall(vim.api.nvim_get_autocmds, { group = group })
    return ok and result or {}
  end

  before_each(function()
    original_windows = state.windows
    original_code_buf = state.current_code_buf
    original_code_win = state.last_code_win_before_opencode
    created_tabs = {}
    created_wins = {}
    created_bufs = {}
    windows = {
      input_buf = vim.api.nvim_create_buf(false, true),
      output_buf = vim.api.nvim_get_current_buf(),
      output_win = vim.api.nvim_get_current_win(),
    }
    state.store.set_raw('windows', windows)
    teardown = stub(ui, 'teardown_visible_windows')
    autocmds.setup_subscriptions()
  end)

  after_each(function()
    autocmds.setup_subscriptions(false)
    teardown:revert()
    for _, tab in ipairs(created_tabs) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        vim.api.nvim_set_current_tabpage(tab)
        vim.cmd('tabclose!')
      end
    end
    for _, win in ipairs(created_wins) do
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end
    for _, buf in ipairs(created_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
      end
    end
    state.store.set_raw('current_code_buf', original_code_buf)
    state.store.set_raw('last_code_win_before_opencode', original_code_win)
    state.store.set_raw('windows', original_windows)
    vim.api.nvim_buf_delete(windows.input_buf, { force = true })
  end)

  it('clears handlers on close and installs them again on restore', function()
    assert.is_true(#handlers('OpencodeWindows') > 0)
    assert.is_true(#handlers('OpencodeResize') > 0)
    state.ui.clear_windows()
    assert.is_true(vim.wait(1000, function()
      return #handlers('OpencodeWindows') == 0 and #handlers('OpencodeResize') == 0
    end))
    state.ui.set_windows(windows)
    assert.is_true(vim.wait(1000, function()
      return #handlers('OpencodeWindows') > 0 and #handlers('OpencodeResize') > 0
    end))
  end)

  it('keeps handler ids stable when folds change and setup is repeated', function()
    local original = handlers('OpencodeWindows')
    autocmds.setup_subscriptions()
    state.ui.set_output_folds({ ranges = {} })
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    assert.is_true(vim.wait(1000, function()
      return drained
    end))
    assert.same(original, handlers('OpencodeWindows'))
  end)

  it('ignores a queued close event after another panel becomes active', function()
    vim.api.nvim_exec_autocmds('WinClosed', { pattern = tostring(windows.output_win) })
    state.ui.set_windows(vim.tbl_extend('force', {}, windows))
    local drained = false
    vim.schedule(function()
      drained = true
    end)
    assert.is_true(vim.wait(1000, function()
      return drained
    end))
    assert.stub(teardown).was_not_called()
  end)

  it('tears down the active panel when its window closes', function()
    vim.api.nvim_exec_autocmds('WinClosed', { pattern = tostring(windows.output_win) })
    assert.is_true(vim.wait(1000, function()
      return #teardown.calls > 0
    end))
    assert.stub(teardown).was_called_with(windows)
  end)

  it('tracks files in the panel tab but ignores floats, other tabs, and window exits', function()
    local function file(name)
      local buf = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. '/' .. name)
      created_bufs[#created_bufs + 1] = buf
      return buf
    end

    local code_buf = file('tracked-code.lua')
    vim.cmd('vsplit')
    local code_win = vim.api.nvim_get_current_win()
    created_wins[#created_wins + 1] = code_win
    vim.api.nvim_win_set_buf(code_win, code_buf)
    assert.equal(code_buf, state.current_code_buf)
    assert.equal(code_win, state.last_code_win_before_opencode)

    local float_buf = file('unrelated-float.lua')
    local float_win = vim.api.nvim_open_win(float_buf, true, {
      relative = 'editor', row = 1, col = 1, width = 20, height = 2,
    })
    created_wins[#created_wins + 1] = float_win
    assert.equal(code_buf, state.current_code_buf)
    vim.api.nvim_win_close(float_win, true)
    assert.equal(code_buf, state.current_code_buf)

    vim.cmd('tabnew')
    local other_tab = vim.api.nvim_get_current_tabpage()
    created_tabs[#created_tabs + 1] = other_tab
    local other_buf = file('unrelated-tab.lua')
    vim.api.nvim_win_set_buf(0, other_buf)
    assert.equal(code_buf, state.current_code_buf)
    vim.cmd('tabclose!')
    assert.equal(code_buf, state.current_code_buf)
    assert.equal(code_win, state.last_code_win_before_opencode)

    local next_buf = file('next-code.lua')
    vim.api.nvim_win_set_buf(code_win, next_buf)
    assert.equal(next_buf, state.current_code_buf)
    assert.equal(code_win, state.last_code_win_before_opencode)
  end)
end)
