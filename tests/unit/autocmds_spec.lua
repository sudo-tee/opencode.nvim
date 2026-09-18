local assert = require('luassert')
local stub = require('luassert.stub')
local state = require('opencode.state')
local autocmds = require('opencode.ui.autocmds')
local ui = require('opencode.ui.ui')

describe('panel autocmd subscriptions', function()
  local original_windows
  local windows
  local teardown

  local function handlers(group)
    local ok, result = pcall(vim.api.nvim_get_autocmds, { group = group })
    return ok and result or {}
  end

  before_each(function()
    original_windows = state.windows
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
end)
