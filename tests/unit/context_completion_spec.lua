local helpers = require('tests.helpers')
local context_completion = require('opencode.ui.completion.context')

local function find_item_by_label(items, label)
  for _, item in ipairs(items) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function find_item_by_pattern(items, pattern)
  for _, item in ipairs(items) do
    if item.label:find(pattern, 1, true) then
      return item
    end
  end
  return nil
end

describe('context completion', function()
  local mock_config, mock_context, mock_state, mock_icons, mock_input_win

  before_each(function()
    mock_config = {
      get_key_for_function = function(category, key)
        if category == 'input_window' and key == 'context_items' then
          return '#'
        end
        return nil
      end,
      context = {
        current_file = { enabled = true },
        selection = { enabled = true },
        diagnostics = { enabled = false },
        cursor_data = { enabled = false },
        files = { enabled = true },
        agents = { enabled = true },
      },
    }

    mock_context = {
      is_context_enabled = function(context_type)
        return mock_config.context[context_type] and mock_config.context[context_type].enabled or false
      end,
      delta_context = function()
        return {
          current_file = { path = '/test/file.lua', name = 'file.lua', extension = 'lua' },
          mentioned_files = { '/test/other.lua', '/test/helper.js' },
          selections = {
            {
              file = { name = 'test.lua', extension = 'lua' },
              content = 'local x = 1',
              lines = '1-1',
            },
          },
          mentioned_subagents = { 'review', 'test' },
          linter_errors = {
            { severity = _G.vim.diagnostic.severity.ERROR },
            { severity = _G.vim.diagnostic.severity.WARN },
          },
          cursor_data = {
            line = 42,
            column = 10,
            line_content = 'local test = "hello"',
          },
        }
      end,
      remove_file = function() end,
      remove_subagent = function() end,
      remove_selection = function() end,
      context = {
        current_file = { extension = 'lua' },
      },
    }

    mock_state = {
      current_context_config = nil,
    }

    mock_input_win = {
      remove_mention = function() end,
      set_current_line = function() end,
    }

    package.loaded['opencode.config'] = mock_config
    package.loaded['opencode.context'] = mock_context
    package.loaded['opencode.state'] = mock_state
    package.loaded['opencode.ui.input_window'] = mock_input_win
  end)

  after_each(function()
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.context'] = nil
    package.loaded['opencode.state'] = nil
    package.loaded['opencode.ui.input_window'] = nil
    package.loaded['opencode.ui.completion.context'] = nil
  end)

  describe('get_source', function()
    it('should return a completion source', function()
      local source = context_completion.get_source()

      assert.are.equal('context', source.name)
      assert.are.equal(1, source.priority)
      assert.is_function(source.complete)
      assert.is_function(source.on_complete)
    end)
  end)

  describe('complete function', function()
    local source

    before_each(function()
      context_completion = require('opencode.ui.completion.context')
      source = context_completion.get_source()
    end)

    it('should return empty table when trigger char does not match', function()
      local completion_context = {
        trigger_char = '/', -- Different from expected '#'
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()
      assert.are.same({}, items)
    end)

    it('should return context items when trigger char matches', function()
      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      assert.is_true(#items >= 3) -- current_file, diagnostics, cursor_data

      local current_file_item = find_item_by_label(items, 'Current File')
      assert.is_not_nil(current_file_item)
      assert.are.equal('context', current_file_item.kind)
      assert.are.equal('current_file', current_file_item.data.type)
    end)

    it('should include selection items when selections exist', function()
      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      local selection_item = find_item_by_label(items, 'Selection (1)')
      assert.is_not_nil(selection_item)
      assert.are.equal('selection', selection_item.data.type)

      local selection_detail = find_item_by_pattern(items, 'Selection 1')
      assert.is_not_nil(selection_detail)
      assert.are.equal('selection_item', selection_detail.data.type)
    end)

    it('should include mentioned files when they exist', function()
      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      mock_config.context.files = { enabled = true }

      local promise2 = source.complete(completion_context)
      local items_with_files = promise2:wait()
      local mentioned_files = vim.tbl_filter(function(item)
        return item.data and item.data.type == 'mentioned_file'
      end, items_with_files)

      assert.are.equal(2, #mentioned_files)
    end)

    it('should include subagent items when they exist', function()
      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      local subagent_items = vim.tbl_filter(function(item)
        return item.data and item.data.type == 'subagent'
      end, items)

      assert.are.equal(2, #subagent_items)

      local review_agent = find_item_by_label(items, 'review (agent)')
      assert.is_not_nil(review_agent)
      assert.are.equal('subagent', review_agent.data.type)
    end)

    it('should filter items based on input', function()
      local completion_context = {
        trigger_char = '#',
        input = 'file',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      for _, item in ipairs(items) do
        assert.is_true(item.label:lower():find('file', 1, true) ~= nil)
      end
    end)

    it('should sort items with available items first', function()
      mock_context.is_context_enabled = function(type)
        return type == 'current_file'
      end

      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()

      assert.is_true(items and #items > 0 and items[1].data.available)

      local first_unavailable_idx = nil
      for i, item in ipairs(items) do
        if not item.data.available then
          first_unavailable_idx = i
          break
        end
      end

      if first_unavailable_idx then
        for i = 1, first_unavailable_idx - 1 do
          assert.is_true(items[i].data.available)
        end
      end
    end)
  end)

  describe('on_complete function', function()
    local source

    before_each(function()
      context_completion = require('opencode.ui.completion.context')
      source = context_completion.get_source()

      vim.fn = vim.fn or {}
      vim.fn.feedkeys = function() end
      vim.fn.fnamemodify = function(path, modifier)
        if modifier == ':~:.' then
          return path:gsub('^/test/', '')
        end
        return path
      end

      vim.api = vim.api or {}
      vim.api.nvim_win_get_cursor = function(...)
        return { 1, 6 }
      end -- Position after '#'
      vim.api.nvim_get_current_line = function()
        return 'test #content'
      end
      vim.api.nvim_replace_termcodes = function(str)
        return str
      end

      vim.schedule = function(fn)
        fn()
      end
    end)

    it('should handle nil item gracefully', function()
      assert.has_no.errors(function()
        source.on_complete(nil)
      end)
    end)

    it('should handle item without data gracefully', function()
      local item = { label = 'test' }
      assert.has_no.errors(function()
        source.on_complete(item)
      end)
    end)

    it('should toggle context enabled state for toggleable items', function()
      local item = {
        label = 'Current File',
        data = {
          type = 'current_file',
          name = 'Current File',
          available = true,
        },
      }

      source.on_complete(item)

      local state_module = require('opencode.state')

      assert.is_not_nil(state_module.current_context_config)
      assert.is_not_nil(state_module.current_context_config.current_file)
      assert.is_false(state_module.current_context_config.current_file.enabled)
    end)

    it('should remove mentioned file when selected', function()
      local remove_file_called = false
      local remove_mention_called = false

      local context_module = require('opencode.context')
      local input_win_module = require('opencode.ui.input_window')

      context_module.remove_file = function(name)
        remove_file_called = true
        assert.are.equal('test.lua', name)
      end

      input_win_module.remove_mention = function(name)
        remove_mention_called = true
        assert.are.equal('test.lua', name)
      end

      local item = {
        label = 'test.lua',
        data = {
          type = 'mentioned_file',
          name = 'test.lua',
          available = true,
        },
      }

      source.on_complete(item)

      assert.is_true(remove_file_called)
      assert.is_true(remove_mention_called)
    end)

    it('should remove subagent when selected', function()
      local remove_subagent_called = false
      local remove_mention_called = false

      local context_module = require('opencode.context')
      local input_win_module = require('opencode.ui.input_window')

      context_module.remove_subagent = function(name)
        remove_subagent_called = true
        assert.are.equal('review', name)
      end

      input_win_module.remove_mention = function(name)
        remove_mention_called = true
        assert.are.equal('review', name)
      end

      local item = {
        label = 'review (agent)',
        data = {
          type = 'subagent',
          name = 'review (agent)',
          available = true,
        },
      }

      source.on_complete(item)

      assert.is_true(remove_subagent_called)
      assert.is_true(remove_mention_called)
    end)

    it('should remove selection when selection item selected', function()
      local remove_selection_called = false
      local selection_data = { content = 'test', lines = '1-1' }

      local context_module = require('opencode.context')

      context_module.remove_selection = function(selection)
        remove_selection_called = true
        assert.are.same(selection_data, selection)
      end

      local item = {
        label = 'Selection 1',
        data = {
          type = 'selection_item',
          name = 'Selection 1',
          available = true,
          additional_data = selection_data,
        },
      }

      source.on_complete(item)

      assert.is_true(remove_selection_called)
    end)

    it('should clean up trigger character from current line', function()
      local set_current_line_called = false

      local input_win_module = require('opencode.ui.input_window')

      input_win_module.set_current_line = function(line)
        set_current_line_called = true
        assert.are.equal('test content', line)
      end

      local item = {
        label = 'test',
        data = {
          type = 'current_file',
          name = 'test',
          available = true,
        },
      }

      source.on_complete(item)

      assert.is_true(set_current_line_called)
    end)
  end)

  describe('formatting functions', function()
    it('should format diagnostics correctly', function()
      mock_context.is_context_enabled = function(type)
        if type == 'diagnostics' then
          return true
        end
        return mock_config.context[type] and mock_config.context[type].enabled or false
      end

      local source = require('opencode.ui.completion.context').get_source()

      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()
      local diagnostics_item = find_item_by_label(items, 'Diagnostics')

      assert.is_not_nil(diagnostics_item)
      assert.is_string(diagnostics_item.documentation)
      assert.is_true(diagnostics_item.documentation:find('Error') ~= nil)
      assert.is_true(diagnostics_item.documentation:find('Warning') ~= nil)
    end)

    it('should format cursor data correctly', function()
      mock_context.is_context_enabled = function(type)
        if type == 'cursor_data' then
          return true
        end
        return mock_config.context[type] and mock_config.context[type].enabled or false
      end

      local source = require('opencode.ui.completion.context').get_source()

      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = source.complete(completion_context)
      local items = promise:wait()
      local cursor_item = find_item_by_label(items, 'Cursor Data')

      assert.is_not_nil(cursor_item)
      assert.is_string(cursor_item.documentation)
      assert.is_true(cursor_item.documentation:find('Line: 42') ~= nil)
      assert.is_true(cursor_item.documentation:find('local test = "hello"') ~= nil)
    end)

    it('should format selection correctly', function()
      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = context_completion.get_source().complete(completion_context)
      local items = promise:wait()
      local selection_detail = find_item_by_pattern(items, 'Selection 1')

      assert.is_not_nil(selection_detail)
      assert.is_string(selection_detail.documentation)
      assert.is_true(selection_detail.documentation:find('```lua') ~= nil)
      assert.is_true(selection_detail.documentation:find('local x = 1') ~= nil)
    end)
  end)

  describe('edge cases', function()
    it('should handle empty context gracefully', function()
      mock_context.delta_context = function()
        return {
          current_file = nil,
          mentioned_files = {},
          selections = {},
          mentioned_subagents = {},
          linter_errors = {},
          cursor_data = {},
        }
      end

      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local promise = context_completion.get_source().complete(completion_context)
      local items = promise:wait()

      assert.is_true(#items >= 3)
    end)

    it('should handle disabled contexts correctly', function()
      local original_is_enabled = mock_context.is_context_enabled
      mock_context.is_context_enabled = function()
        return false
      end

      local completion_context = {
        trigger_char = '#',
        input = '',
      }

      local source = require('opencode.ui.completion.context').get_source()
      local items = source.complete(completion_context)

      mock_context.is_context_enabled = original_is_enabled

      for _, item in ipairs(items) do
        if vim.tbl_contains({ 'current_file', 'selection', 'diagnostics', 'cursor_data' }, item.data.type) then
          assert.is_false(item.data.available)
        end
      end
    end)
  end)
end)
