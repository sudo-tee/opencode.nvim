local context = require('opencode.context')
local state = require('opencode.state')
local assert = require('luassert')

describe('extract_from_opencode_message', function()
  it('extracts prompt, selected_text, and current_file from tags in parts', function()
    local message = {
      parts = {
        { type = 'text', text = 'What does this code do?' },
        {
          type = 'text',
          synthetic = true,
          text = vim.json.encode({ context_type = 'selection', content = 'print(42)' }),
        },
        { type = 'file', filename = '/tmp/foo.lua' },
      },
    }
    local result = context.extract_from_opencode_message(message)
    assert.equal('What does this code do?', result.prompt)
    assert.equal('print(42)', result.selected_text)
    assert.equal('/tmp/foo.lua', result.current_file)
  end)

  it('returns nils if message or parts missing', function()
    assert.same({ prompt = nil, selected_text = nil, current_file = nil }, context.extract_from_opencode_message(nil))
    assert.same({ prompt = nil, selected_text = nil, current_file = nil }, context.extract_from_opencode_message({}))
  end)
end)

describe('extract_from_message_legacy', function()
  it('extracts legacy tags from text', function()
    local text =
      '<user-query>foo</user-query> <manually-added-selection>bar</manually-added-selection> <current-file>Path: /tmp/x.lua</current-file>'
    local result = context.extract_from_message_legacy(text)
    assert.equal('foo', result.prompt)
    assert.equal('bar', result.selected_text)
    assert.equal('/tmp/x.lua', result.current_file)
  end)
end)

describe('extract_legacy_tag', function()
  it('extracts content between tags', function()
    local text = '<foo>bar</foo>'
    assert.equal('bar', context.extract_legacy_tag('foo', text))
  end)
  it('returns nil if tag not found', function()
    assert.is_nil(context.extract_legacy_tag('baz', 'no tags here'))
  end)
end)

describe('format_message', function()
  local original_delta_context
  local original_get_context
  local mock_context

  before_each(function()
    mock_context = {
      current_file = nil,
      mentioned_files = nil,
      mentioned_subagents = nil,
      selections = nil,
      linter_errors = nil,
      cursor_data = nil,
    }
    
    original_delta_context = context.delta_context
    original_get_context = context.get_context
    
    context.get_context = function()
      return mock_context
    end
    
    context.delta_context = function()
      return context.get_context()
    end
  end)

  after_each(function()
    context.delta_context = original_delta_context
    context.get_context = original_get_context
  end)

  it('returns a parts array with prompt as first part', function()
    local parts = context.format_message('hello world'):wait()
    assert.is_table(parts)
    assert.equal('hello world', parts[1].text)
    assert.equal('text', parts[1].type)
  end)
  it('includes mentioned_files and subagents', function()
    local ChatContext = require('opencode.context.chat_context')
    ChatContext.context.mentioned_files = { '/tmp/foo.lua' }
    ChatContext.context.mentioned_subagents = { 'agent1' }
    local parts = context.format_message('prompt @foo.lua @agent1'):wait()
    assert.is_true(#parts > 2)
    local found_file, found_agent = false, false
    for _, p in ipairs(parts) do
      if p.type == 'file' then
        found_file = true
      end
      if p.type == 'agent' then
        found_agent = true
      end
    end
    assert.is_true(found_file)
    assert.is_true(found_agent)
  end)

  it('includes selection even when current_file context is disabled', function()
    local ChatContext = require('opencode.context.chat_context')
    local BaseContext = require('opencode.context.base_context')
    local original_get_current_buf = BaseContext.get_current_buf
    local original_get_current_selection = BaseContext.get_current_selection
    local original_get_current_file_for_selection = BaseContext.get_current_file_for_selection

    ChatContext.context.current_file = nil
    ChatContext.context.mentioned_files = {}
    ChatContext.context.mentioned_subagents = {}
    ChatContext.context.selections = {}

    BaseContext.get_current_buf = function()
      return 1, 1
    end
    BaseContext.get_current_selection = function()
      return { text = 'print("hello")', lines = '3, 4' }
    end
    BaseContext.get_current_file_for_selection = function()
      return { path = '/tmp/foo.lua', name = 'foo.lua', extension = 'lua' }
    end

    local parts = context.format_message('test prompt', {
      current_file = { enabled = false },
      selection = { enabled = true },
    }):wait()

    local selection_json = nil
    local has_file_part = false
    for _, part in ipairs(parts) do
      if part.type == 'file' then
        has_file_part = true
      end
      local json = context.decode_json_context(part.text or '', 'selection')
      if json then
        selection_json = json
      end
    end

    assert.is_false(has_file_part)
    assert.is_not_nil(selection_json)
    assert.same({ path = '/tmp/foo.lua', name = 'foo.lua', extension = 'lua' }, selection_json.file)

    BaseContext.get_current_buf = original_get_current_buf
    BaseContext.get_current_selection = original_get_current_selection
    BaseContext.get_current_file_for_selection = original_get_current_file_for_selection
  end)
end)

describe('delta_context', function()
  local mock_context
  local original_get_context

  before_each(function()
    mock_context = {
      current_file = nil,
      mentioned_files = nil,
      mentioned_subagents = nil,
      selections = nil,
      linter_errors = nil,
      cursor_data = nil,
    }
    
    original_get_context = context.get_context
    context.get_context = function()
      return mock_context
    end
  end)

  after_each(function()
    context.get_context = original_get_context
  end)
  it('removes current_file if unchanged', function()
    local file = { name = 'foo.lua', path = '/tmp/foo.lua', extension = 'lua' }
    mock_context.current_file = vim.deepcopy(file)
    state.last_sent_context = { current_file = mock_context.current_file }
    local result = context.delta_context()
    assert.is_nil(result.current_file)
  end)
  it('removes mentioned_subagents if unchanged', function()
    local subagents = { 'a' }
    mock_context.mentioned_subagents = vim.deepcopy(subagents)
    state.last_sent_context = { mentioned_subagents = vim.deepcopy(subagents) }
    local result = context.delta_context()
    assert.is_nil(result.mentioned_subagents)
  end)
end)

describe('add_file/add_selection/add_subagent', function()
  local ChatContext = require('opencode.context.chat_context')
  local original_context

  before_each(function()
    -- Store original context
    original_context = vim.deepcopy(ChatContext.context)
    
    -- Reset to clean state
    ChatContext.context.mentioned_files = {}
    ChatContext.context.selections = {}
    ChatContext.context.mentioned_subagents = {}
    
    context.delta_context()
  end)

  after_each(function()
    -- Restore original context
    for k, v in pairs(original_context) do
      ChatContext.context[k] = v
    end
  end)
  it('adds a file if filereadable', function()
    vim.fn.filereadable = function()
      return 1
    end
    local util = require('opencode.util')
    local original_is_path_in_cwd = util.is_path_in_cwd
    util.is_path_in_cwd = function()
      return true
    end

    context.add_file('/tmp/foo.lua')
    assert.same({ '/tmp/foo.lua' }, context.get_context().mentioned_files)

    util.is_path_in_cwd = original_is_path_in_cwd
  end)
  it('does not add file if not filereadable', function()
    vim.fn.filereadable = function()
      return 0
    end
    context.add_file('/tmp/bar.lua')
    assert.same({}, context.get_context().mentioned_files)
  end)
  it('adds a selection', function()
    context.add_selection({ foo = 'bar' })
    assert.same({ { foo = 'bar' } }, context.get_context().selections)
  end)
  it('adds a subagent', function()
    context.add_subagent('agentX')
    assert.same({ 'agentX' }, context.get_context().mentioned_subagents)
  end)
end)

describe('context static API with config override', function()
  it('should use override config for context enabled checks', function()
    local override_config = {
      current_file = { enabled = false },
      diagnostics = { enabled = false },
      selection = { enabled = true },
      agents = { enabled = true },
    }

    -- Test using static API with config parameter
    assert.is_false(context.is_context_enabled('current_file', override_config))
    assert.is_false(context.is_context_enabled('diagnostics', override_config))
    assert.is_true(context.is_context_enabled('selection', override_config))
    assert.is_true(context.is_context_enabled('agents', override_config))
  end)

  it('should fall back to global config when override not provided', function()
    local override_config = {
      current_file = { enabled = false },
      -- other context types not specified
    }

    -- Test using static API with partial config
    assert.is_false(context.is_context_enabled('current_file', override_config))

    -- other context types should fall back to normal behavior
    -- (these will use global config + state, tested elsewhere)
  end)

  it('should work without any override config', function()
    -- Should behave exactly like global context using static API
    assert.is_not_nil(context.is_context_enabled('current_file'))
    assert.is_not_nil(context.is_context_enabled('diagnostics'))
  end)
end)

describe('get_diagnostics with chat context selections', function()
  local ChatContext
  
  before_each(function()
    ChatContext = require('opencode.context.chat_context')
    -- Reset chat context
    ChatContext.context = {
      mentioned_files = {},
      selections = {},
      mentioned_subagents = {},
      current_file = nil,
      cursor_data = nil,
      linter_errors = nil,
    }
  end)

  it('should use chat context selection range when no explicit range provided', function()
    -- Add a mock selection to chat context
    local mock_selection = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("hello")',
      lines = '5, 8'  -- Lines 5 to 8 (1-based)
    }
    ChatContext.add_selection(mock_selection)

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      return {}
    end

    -- Call get_diagnostics without an explicit range
    ChatContext.get_diagnostics(1, nil, nil)

    -- Verify that a list of ranges was passed to base_context
    assert.is_not_nil(captured_range)
    assert.equal('table', type(captured_range))
    assert.equal(1, #captured_range)  -- Should have one range in the list
    assert.equal(4, captured_range[1].start_line)  -- 5 - 1 (0-based)
    assert.equal(7, captured_range[1].end_line)    -- 8 - 1 (0-based)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)

  it('should prioritize explicit range over chat context selections', function()
    -- Add a mock selection to chat context
    local mock_selection = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("hello")',
      lines = '5, 8'
    }
    ChatContext.add_selection(mock_selection)

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      return {}
    end

    -- Call get_diagnostics with an explicit range
    local explicit_range = { start_line = 10, end_line = 15 }
    ChatContext.get_diagnostics(1, nil, explicit_range)

    -- Verify that the explicit range was used, not the selection range
    assert.is_not_nil(captured_range)
    assert.equal(10, captured_range.start_line)
    assert.equal(15, captured_range.end_line)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)

  it('should handle dash-separated line format in selections', function()
    -- Add a mock selection with dash format (used by range-based selections)
    local mock_selection = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("hello")',
      lines = '3-7'  -- Lines 3 to 7 with dash separator
    }
    ChatContext.add_selection(mock_selection)

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      return {}
    end

    -- Call get_diagnostics without an explicit range
    ChatContext.get_diagnostics(1, nil, nil)

    -- Verify that a list of ranges was passed and parsed correctly from dash format
    assert.is_not_nil(captured_range)
    assert.equal('table', type(captured_range))
    assert.equal(1, #captured_range)  -- Should have one range in the list
    assert.equal(2, captured_range[1].start_line)  -- 3 - 1 (0-based)
    assert.equal(6, captured_range[1].end_line)    -- 7 - 1 (0-based)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)

  it('should fallback to cursor behavior when no selections exist', function()
    -- Ensure no selections in chat context
    ChatContext.clear_selections()

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      return {}
    end

    -- Call get_diagnostics without an explicit range
    ChatContext.get_diagnostics(1, nil, nil)

    -- Verify that no range was passed (should fallback to cursor behavior)
    assert.is_nil(captured_range)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)

  it('should collect diagnostics from all selection ranges individually', function()
    -- Add multiple selections to chat context
    local selection1 = {
      file = { path = '/tmp/test1.lua', name = 'test1.lua', extension = 'lua' },
      content = 'print("first")',
      lines = '3, 5'
    }
    local selection2 = {
      file = { path = '/tmp/test2.lua', name = 'test2.lua', extension = 'lua' },
      content = 'print("second")',
      lines = '10, 12'
    }
    local selection3 = {
      file = { path = '/tmp/test3.lua', name = 'test3.lua', extension = 'lua' },
      content = 'print("third")',
      lines = '7, 8'
    }
    ChatContext.add_selection(selection1)
    ChatContext.add_selection(selection2)
    ChatContext.add_selection(selection3)

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      -- Return mock diagnostics for all ranges
      if range and type(range) == 'table' and range[1] then
        local result = {}
        for i, r in ipairs(range) do
          table.insert(result, {
            lnum = r.start_line,
            col = 0,
            message = 'Mock diagnostic for range ' .. r.start_line .. '-' .. r.end_line,
            severity = 1
          })
        end
        return result
      end
      return {}
    end

    -- Call get_diagnostics without an explicit range
    local result = ChatContext.get_diagnostics(1, nil, nil)

    -- Verify that a single range list was passed containing all selections
    assert.is_not_nil(captured_range)
    assert.equal('table', type(captured_range))
    assert.equal(3, #captured_range)  -- Should have three ranges in the list
    
    -- Check each range matches the selections
    assert.equal(2, captured_range[1].start_line)   -- 3 - 1 (0-based)
    assert.equal(4, captured_range[1].end_line)     -- 5 - 1 (0-based)
    
    assert.equal(9, captured_range[2].start_line)   -- 10 - 1 (0-based)
    assert.equal(11, captured_range[2].end_line)    -- 12 - 1 (0-based)
    
    assert.equal(6, captured_range[3].start_line)   -- 7 - 1 (0-based)
    assert.equal(7, captured_range[3].end_line)     -- 8 - 1 (0-based)
    
    -- Verify that all diagnostics from all ranges are combined in the result
    assert.equal(3, #result)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)

  it('should handle mixed line formats in multiple selection ranges', function()
    -- Add selections with different line formats
    local selection1 = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("first")',
      lines = '15-17'  -- Dash format
    }
    local selection2 = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("second")',
      lines = '2, 4'   -- Comma format
    }
    local selection3 = {
      file = { path = '/tmp/test.lua', name = 'test.lua', extension = 'lua' },
      content = 'print("third")',
      lines = '20'     -- Single line
    }
    
    ChatContext.add_selection(selection1)
    ChatContext.add_selection(selection2)
    ChatContext.add_selection(selection3)

    -- Mock the BaseContext.get_diagnostics to capture the range parameter
    local BaseContext = require('opencode.context.base_context')
    local captured_range = nil
    local original_get_diagnostics = BaseContext.get_diagnostics
    BaseContext.get_diagnostics = function(buf, context_config, range)
      captured_range = range
      -- Return mock diagnostics for all ranges
      if range and type(range) == 'table' and range[1] then
        local result = {}
        for i, r in ipairs(range) do
          table.insert(result, {
            lnum = r.start_line,
            col = 0,
            message = 'Mock diagnostic',
            severity = 1
          })
        end
        return result
      end
      return {}
    end

    -- Call get_diagnostics without an explicit range
    local result = ChatContext.get_diagnostics(1, nil, nil)

    -- Verify that a single range list was passed containing all selections
    assert.is_not_nil(captured_range)
    assert.equal('table', type(captured_range))
    assert.equal(3, #captured_range)  -- Should have three ranges in the list
    
    -- Check ranges for different line formats
    assert.equal(14, captured_range[1].start_line)  -- 15 - 1 (0-based)
    assert.equal(16, captured_range[1].end_line)    -- 17 - 1 (0-based)
    
    assert.equal(1, captured_range[2].start_line)   -- 2 - 1 (0-based)
    assert.equal(3, captured_range[2].end_line)     -- 4 - 1 (0-based)
    
    assert.equal(19, captured_range[3].start_line)  -- 20 - 1 (0-based, single line)
    assert.equal(19, captured_range[3].end_line)    -- 20 - 1 (0-based, single line)
    
    -- Verify that all diagnostics from all ranges are combined in the result
    assert.equal(3, #result)

    -- Restore original function
    BaseContext.get_diagnostics = original_get_diagnostics
  end)
end)
