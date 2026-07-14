local Dialog = require('opencode.ui.dialog')
local Output = require('opencode.ui.output')
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

  describe('question keymaps', function()
    local function map_callback(key)
      return vim.fn.maparg(key, 'n', false, true).callback
    end

    it('maps Tab only when a single-select dialog requests an alias', function()
      vim.api.nvim_set_current_win(output_win)

      local selected = 0
      local question_dialog = Dialog.new({
        buffer = output_buf,
        on_select = function()
          selected = selected + 1
        end,
        get_option_count = function()
          return 1
        end,
        hide_input = false,
        keymaps = { select_aliases = { '<Tab>' } },
      })
      question_dialog:setup()

      assert.is_function(map_callback('<Tab>'))
      map_callback('<Tab>')()
      assert.are.equal(1, selected)
      question_dialog:teardown()

      local permission_dialog = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 1
        end,
        hide_input = false,
      })
      permission_dialog:setup()

      assert.is_nil(map_callback('<Tab>'))
      local permission_output = Output.new()
      permission_dialog:format_legend(permission_output)
      local legend = table.concat(permission_output.lines, '\n')
      assert.is_truthy(legend:find('Select: `<CR>`'))
      assert.is_nil(legend:find('Edit'))
      permission_dialog:teardown()
    end)

    it('uses Enter, Tab, and Space to act on a multi-select choice', function()
      vim.api.nvim_set_current_win(output_win)

      local selected = 0
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function()
          selected = selected + 1
        end,
        get_option_count = function()
          return 1
        end,
        is_multiple = true,
        hide_input = false,
        keymaps = { toggle_aliases = { '<Space>' } },
      })
      dialog:setup()

      assert.are.equal(1, vim.fn.maparg('<Space>', 'n', false, true).nowait)
      map_callback('<Tab>')()
      map_callback('<Space>')()
      map_callback('<CR>')()

      assert.are.equal(3, selected)
      dialog:teardown()
    end)

    it('submits a trailing action row only with Enter', function()
      vim.api.nvim_set_current_win(output_win)

      local selected = {}
      local dialog = Dialog.new({
        buffer = output_buf,
        on_select = function(index)
          table.insert(selected, index)
        end,
        get_option_count = function()
          return 2
        end,
        get_shortcut_count = function()
          return 1
        end,
        is_multiple = true,
        hide_input = false,
        keymaps = { toggle_aliases = { '<Space>' } },
      })
      dialog:setup()
      dialog:set_selection(2)

      map_callback('<Tab>')()
      map_callback('<Space>')()
      assert.are.same({}, selected)
      assert.is_nil(map_callback('2'))

      map_callback('<CR>')()
      assert.are.same({ 2 }, selected)
      dialog:teardown()
    end)

    it('derives question legends from the configured keymaps', function()
      vim.api.nvim_set_current_win(output_win)

      local single = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 2
        end,
        hide_input = false,
        keymaps = { select_aliases = { '<Tab>' } },
      })
      single:setup()
      local single_output = Output.new()
      single:format_legend(single_output)
      assert.is_truthy(table.concat(single_output.lines, '\n'):find('Choose/Edit: `<CR>` or `<Tab>` or `1%-2`'))
      single:teardown()

      local multiple = Dialog.new({
        buffer = output_buf,
        on_select = function() end,
        get_option_count = function()
          return 2
        end,
        get_shortcut_count = function()
          return 1
        end,
        is_multiple = true,
        hide_input = false,
        keymaps = { toggle_aliases = { '<Space>' } },
      })
      multiple:setup()
      local multiple_output = Output.new()
      multiple:format_legend(multiple_output)
      local legend = table.concat(multiple_output.lines, '\n')
      assert.is_truthy(legend:find('Toggle/Edit: `<CR>` or `<Tab>` or `<Space>` or `1%-1`'))
      assert.is_truthy(legend:find('Submit: select Confirm and press `<CR>`'))
      for _, extmarks in pairs(multiple_output.extmarks) do
        for _, extmark in ipairs(extmarks) do
          assert.are_not.equal('OpencodeQuestionTabPending', extmark.line_hl_group)
        end
      end
      multiple:teardown()
    end)
  end)
end)

describe('Dialog formatting', function()
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
