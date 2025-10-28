local context_bar = require('opencode.ui.context_bar')
local context = require('opencode.context')
local state = require('opencode.state')
local icons = require('opencode.ui.icons')
local assert = require('luassert')

describe('opencode.ui.context_bar', function()
  local original_delta_context
  local original_is_context_enabled
  local original_get_icon
  local original_subscribe
  local original_schedule
  local original_api_win_is_valid
  local original_api_get_option_value
  local original_api_set_option_value
  local original_vim_tbl_contains
  local original_wo
  local mock_context

  local function create_mock_window(win_id)
    local captured_winbar = {}
    vim.wo[win_id] = setmetatable({}, {
      __newindex = function(_, key, value)
        if key == 'winbar' then
          captured_winbar.value = value
          captured_winbar.set = true
        end
      end,
    })
    return captured_winbar
  end

  before_each(function()
    original_delta_context = context.delta_context
    original_is_context_enabled = context.is_context_enabled
    original_get_icon = icons.get
    original_subscribe = state.subscribe
    original_schedule = vim.schedule
    original_api_win_is_valid = vim.api.nvim_win_is_valid
    original_api_get_option_value = vim.api.nvim_get_option_value
    original_api_set_option_value = vim.api.nvim_set_option_value
    original_vim_tbl_contains = vim.tbl_contains
    original_wo = vim.wo

    mock_context = {
      current_file = nil,
      mentioned_files = nil,
      mentioned_subagents = nil,
      selections = nil,
      linter_errors = nil,
      cursor_data = nil,
    }

    context.delta_context = function()
      return mock_context
    end

    context.is_context_enabled = function(_)
      return true -- Enable all context types by default
    end

    state.subscribe = function(_, _)
      -- Mock implementation
    end

    vim.schedule = function(callback)
      callback() -- Execute immediately for tests
    end

    vim.api.nvim_win_is_valid = function(_)
      return true
    end

    vim.api.nvim_get_option_value = function(_, _)
      return 'StatusLine:MyStatusLine'
    end

    vim.api.nvim_set_option_value = function(_, _, _)
      -- Mock implementation
    end

    vim.tbl_contains = function(table, value)
      for _, v in ipairs(table) do
        if v == value then
          return true
        end
      end
      return false
    end

    vim.wo = {}

    -- Reset state
    state.windows = nil
  end)

  after_each(function()
    -- Restore original functions
    context.delta_context = original_delta_context
    context.is_context_enabled = original_is_context_enabled
    icons.get = original_get_icon
    state.subscribe = original_subscribe
    vim.schedule = original_schedule
    vim.api.nvim_win_is_valid = original_api_win_is_valid
    vim.api.nvim_get_option_value = original_api_get_option_value
    vim.api.nvim_set_option_value = original_api_set_option_value
    vim.tbl_contains = original_vim_tbl_contains
    vim.wo = original_wo
  end)

  describe('opencode.ui.context_bar', function()
    it('renders minimal winbar with context icon only', function()
      local mock_input_win = 2001
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('context')))
    end)

    it('renders winbar with current file when present', function()
      mock_context.current_file = {
        name = 'test.lua',
        path = '/tmp/test.lua',
      }

      local mock_input_win = 2002
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('attached_file') .. 'test%.lua'))
    end)

    it('renders winbar with multiple context elements', function()
      mock_context.current_file = { name = 'main.lua', path = '/src/main.lua' }
      mock_context.mentioned_files = { '/file1.lua', '/file2.lua' }
      mock_context.mentioned_subagents = { 'agent1' }
      mock_context.selections = { { text = 'code' } }
      mock_context.cursor_data = { line = 10, col = 5 }

      local mock_input_win = 2003
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('attached_file') .. 'main%.lua'))
      assert.is_not_nil(winbar_capture.value:find(icons.get('file') .. '%(2%)'))
      assert.is_not_nil(winbar_capture.value:find(icons.get('agent') .. '%(1%)'))
      assert.is_not_nil(winbar_capture.value:find('L:10')) -- Cursor data
    end)

    it('renders winbar with diagnostics', function()
      mock_context.linter_errors = {
        { severity = 1 }, -- ERROR
        { severity = 1 }, -- ERROR
        { severity = 2 }, -- WARN
        { severity = 3 }, -- INFO
      }

      local mock_input_win = 2004
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('error') .. '%(2%)')) -- 2 errors
      assert.is_not_nil(winbar_capture.value:find(icons.get('warning') .. '%(1%)')) -- Warning icon
      assert.is_not_nil(winbar_capture.value:find(icons.get('info') .. '%(1%)')) -- Info icon
    end)

    it('respects context enabled settings', function()
      context.is_context_enabled = function(context_type)
        return context_type == 'current_file' -- Only enable current_file
      end

      mock_context.current_file = { name = 'test.lua', path = '/test.lua' }
      mock_context.mentioned_files = { '/file1.lua' }
      mock_context.selections = { { text = 'code' } }

      local mock_input_win = 2005
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('attached_file') .. 'test%.lua')) -- attahced file icon
      assert.is_nil(winbar_capture.value:find(icons.get('file') .. '%(1%)'))
      assert.is_nil(winbar_capture.value:find(icons.get('selection') .. '%(1%)'))
    end)

    it('handles empty winbar gracefully', function()
      mock_context = {} -- Empty context

      local mock_input_win = 2006
      local winbar_capture = create_mock_window(mock_input_win)

      state.windows = { input_win = mock_input_win }
      context_bar.render()

      assert.is_string(winbar_capture.value)
      assert.is_not_nil(winbar_capture.value:find(icons.get('context'))) -- Should still have context icon
    end)

    it('does nothing when window is invalid', function()
      vim.api.nvim_win_is_valid = function(_)
        return false
      end

      local mock_input_win = 2007
      local winbar_capture = create_mock_window(mock_input_win)

      context_bar.render({ input_win = mock_input_win })
      assert.is_nil(winbar_capture.set)
    end)

    it('uses provided windows parameter', function()
      local custom_windows = { input_win = 2008 }
      local winbar_capture = create_mock_window(2008)

      context_bar.render(custom_windows)
      assert.is_string(winbar_capture.value)
    end)
  end)

  describe('setup', function()
    it('subscribes to state changes', function()
      local subscription_called = false
      local captured_keys = nil

      state.subscribe = function(keys, callback)
        subscription_called = true
        captured_keys = keys
        assert.is_table(keys)
        assert.is_function(callback)
      end

      context_bar.setup()
      assert.is_true(subscription_called)
      assert.is_table(captured_keys)

      local expected_keys = { 'current_context_config', 'current_code_buf', 'opencode_focused', 'context_updated_at' }
      for _, expected_key in ipairs(expected_keys) do
        local found = false
        for _, key in ipairs(captured_keys) do
          if key == expected_key then
            found = true
            break
          end
        end
        assert.is_true(found, 'Expected key not found: ' .. expected_key)
      end
    end)
  end)
end)
