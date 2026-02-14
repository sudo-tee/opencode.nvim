local Dialog = require('opencode.ui.dialog')
local state = require('opencode.state')
local config = require('opencode.config')

describe('Dialog', function()
  local input_buf, output_buf, input_win, output_win
  local original_auto_hide

  before_each(function()
    -- Save original config
    original_auto_hide = config.ui.input.auto_hide

    -- Create test buffers and windows
    input_buf = vim.api.nvim_create_buf(false, true)
    output_buf = vim.api.nvim_create_buf(false, true)
    input_win = vim.api.nvim_open_win(input_buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
    output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 11,
      col = 0,
    })

    state.windows = {
      input_buf = input_buf,
      input_win = input_win,
      output_buf = output_buf,
      output_win = output_win,
    }

    -- Mock input_window module
    package.loaded['opencode.ui.input_window'] = nil
  end)

  after_each(function()
    -- Restore original config
    config.ui.input.auto_hide = original_auto_hide

    -- Clean up windows and buffers
    pcall(vim.api.nvim_win_close, input_win, true)
    pcall(vim.api.nvim_win_close, output_win, true)
    pcall(vim.api.nvim_buf_delete, input_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })

    state.windows = nil
    package.loaded['opencode.ui.input_window'] = nil
  end)

  describe('teardown with hide_input enabled', function()
    it('should show input window when auto_hide is disabled', function()
      config.ui.input.auto_hide = false

      local show_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function() end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()
      dialog:teardown()

      assert.is_true(show_called, 'input window should be shown when auto_hide is disabled')
    end)

    it('should NOT show input window when auto_hide is enabled', function()
      config.ui.input.auto_hide = true

      local show_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function() end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()
      dialog:teardown()

      assert.is_false(show_called, 'input window should NOT be shown when auto_hide is enabled')
    end)

    it('should not call _show when hide_input is disabled', function()
      config.ui.input.auto_hide = false

      local show_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function() end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = false, -- Dialog doesn't manage input window
      })

      dialog:setup()
      dialog:teardown()

      assert.is_false(show_called, 'input window should not be managed when hide_input is false')
    end)
  end)

  describe('setup with hide_input enabled', function()
    it('should hide input window during setup', function()
      config.ui.input.auto_hide = false

      local hide_called = false
      local input_window = {
        _show = function() end,
        _hide = function()
          hide_called = true
        end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()

      assert.is_true(hide_called, 'input window should be hidden during dialog setup')
    end)

    it('should hide input window during setup even with auto_hide enabled', function()
      config.ui.input.auto_hide = true

      local hide_called = false
      local input_window = {
        _show = function() end,
        _hide = function()
          hide_called = true
        end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()

      assert.is_true(hide_called, 'input window should be hidden during dialog setup regardless of auto_hide')
    end)
  end)

  describe('regression test for question and permission dialogs', function()
    it('should not show input after answering question with auto_hide enabled', function()
      config.ui.input.auto_hide = true

      local show_called = false
      local hide_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function()
          hide_called = true
        end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      -- Simulate question dialog flow
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()
      assert.is_true(hide_called, 'input should be hidden when question appears')

      show_called = false -- reset
      dialog:teardown()
      assert.is_false(show_called, 'input should NOT be shown after answering question with auto_hide enabled')
    end)

    it('should not show input after responding to permission with auto_hide enabled', function()
      config.ui.input.auto_hide = true

      local show_called = false
      local hide_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function()
          hide_called = true
        end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      -- Simulate permission dialog flow
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()
      assert.is_true(hide_called, 'input should be hidden when permission prompt appears')

      show_called = false -- reset
      dialog:teardown()
      assert.is_false(show_called, 'input should NOT be shown after responding to permission with auto_hide enabled')
    end)

    it('should show input after answering question with auto_hide disabled', function()
      config.ui.input.auto_hide = false

      local show_called = false
      local hide_called = false
      local input_window = {
        _show = function()
          show_called = true
        end,
        _hide = function()
          hide_called = true
        end,
      }
      package.loaded['opencode.ui.input_window'] = input_window

      -- Simulate question dialog flow
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 3
        end,
        hide_input = true,
      })

      dialog:setup()
      assert.is_true(hide_called, 'input should be hidden when question appears')

      show_called = false -- reset
      dialog:teardown()
      assert.is_true(show_called, 'input should be shown after answering question with auto_hide disabled')
    end)
  end)
end)
