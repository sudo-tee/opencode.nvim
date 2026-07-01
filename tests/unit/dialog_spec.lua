local Dialog = require('opencode.ui.dialog')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local config = require('opencode.config')

describe('Dialog', function()
  local input_buf, output_buf, input_win, output_win
  local original_auto_hide

  local function keymap_callback(buf, lhs)
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(buf, 'n')) do
      if keymap.lhs:lower() == lhs:lower() then
        return keymap.callback
      end
    end
  end

  local function with_mousepos(mousepos, callback)
    local original_getmousepos = vim.fn.getmousepos
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.fn.getmousepos = function()
      return mousepos
    end

    local ok, err = pcall(callback)
    vim.fn.getmousepos = original_getmousepos
    if not ok then
      error(err)
    end
  end

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

    state.ui.set_windows({
      input_buf = input_buf,
      input_win = input_win,
      output_buf = output_buf,
      output_win = output_win,
    })

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

    state.ui.clear_windows()
    require('opencode.ui.renderer.ctx'):reset()
    package.loaded['opencode.ui.input_window'] = nil
  end)

  describe('mouse option selection', function()
    it('selects an option by rendered part line plus tracked option line', function()
      local selected = nil
      local dialog = Dialog.new({
        buffer = output_buf,
        render_part_id = 'dialog-test-part',
        mouse_select = true,
        on_select = function(index)
          selected = index
        end,
        get_option_count = function()
          return 3
        end,
        hide_input = false,
      })

      dialog:setup()

      local output = Output.new()
      dialog:format_options(output, {
        { label = 'First' },
        { label = 'Second' },
        { label = 'Third' },
      })

      require('opencode.ui.renderer.ctx').render_state:set_part({ id = 'dialog-test-part' }, 20, 30)

      with_mousepos({
        winid = output_win,
        line = 20 + dialog._option_local_lines[2] + 1,
        column = 1,
      }, function()
        keymap_callback(output_buf, '<LeftMouse>')()
      end)

      assert.are.equal(2, selected)
      assert.are.equal(2, dialog:get_selection())

      dialog:teardown()
    end)

    it('ignores clicks outside tracked option lines', function()
      local selected = nil
      local dialog = Dialog.new({
        buffer = output_buf,
        render_part_id = 'dialog-test-part',
        mouse_select = true,
        on_select = function(index)
          selected = index
        end,
        get_option_count = function()
          return 2
        end,
        hide_input = false,
      })

      dialog:setup()

      local output = Output.new()
      dialog:format_options(output, {
        { label = 'First' },
        { label = 'Second' },
      })

      require('opencode.ui.renderer.ctx').render_state:set_part({ id = 'dialog-test-part' }, 20, 30)

      with_mousepos({
        winid = output_win,
        line = 20 + 9 + 1,
        column = 1,
      }, function()
        keymap_callback(output_buf, '<LeftMouse>')()
      end)

      assert.is_nil(selected)
      assert.are.equal(1, dialog:get_selection())

      dialog:teardown()
    end)
  end)

  describe('dismiss keymaps', function()
    it('maps both default dismiss keys', function()
      local dismiss_count = 0
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        on_dismiss = function()
          dismiss_count = dismiss_count + 1
        end,
        get_option_count = function()
          return 1
        end,
        hide_input = false,
      })

      dialog:setup()

      keymap_callback(output_buf, '<Esc>')()
      keymap_callback(output_buf, '<C-c>')()

      assert.are.equal(2, dismiss_count)

      dialog:teardown()
    end)

    it('does not map dismiss when dismiss is an empty string', function()
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 1
        end,
        hide_input = false,
        keymaps = {
          dismiss = '',
        },
      })

      dialog:setup()

      assert.is_nil(keymap_callback(output_buf, '<Esc>'))
      assert.is_nil(keymap_callback(output_buf, '<C-c>'))

      dialog:teardown()
    end)

    it('does not map dismiss when dismiss is an empty list', function()
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 1
        end,
        hide_input = false,
        keymaps = {
          dismiss = {},
        },
      })

      dialog:setup()

      assert.is_nil(keymap_callback(output_buf, '<Esc>'))
      assert.is_nil(keymap_callback(output_buf, '<C-c>'))

      dialog:teardown()
    end)
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

describe('Dialog formatting', function()
  it('tracks option lines from the line returned by add_line', function()
    local dialog = Dialog.new({
      buffer = 0,
      on_select = function() end,
      get_option_count = function()
        return 2
      end,
    })

    local output = Output.new()
    output:add_line('content before options')

    dialog:format_options(output, {
      { label = 'First' },
      { label = 'Second' },
    })

    assert.are.same({ 1, 2 }, dialog._option_local_lines)
  end)

  it('places selection extmarks on the selected option line', function()
    local dialog = Dialog.new({
      buffer = 0,
      on_select = function() end,
      get_option_count = function()
        return 3
      end,
    })

    dialog:set_selection(2)

    local output = Output.new()
    dialog:format_options(output, {
      { label = 'First' },
      { label = 'Second' },
      { label = 'Third' },
    })

    assert.are.same({
      '    1. First',
      '    2. Second ',
      '    3. Third',
    }, output:get_lines())

    assert.is_nil(output.extmarks[0])
    assert.is_not_nil(output.extmarks[1])
    assert.is_nil(output.extmarks[2])
    assert.are.equal('OpencodeDialogOptionHover', output.extmarks[1][1].line_hl_group)
    assert.are.same({ { '› ', 'OpencodeDialogOptionHover' } }, output.extmarks[1][2].virt_text)
  end)
end)
