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
  before_each(function()
    context.context.current_file = nil
    context.context.mentioned_files = nil
    context.context.mentioned_subagents = nil
    context.context.selections = nil
    context.context.linter_errors = nil
    context.context.cursor_data = nil
    original_delta_context = context.delta_context
    context.delta_context = function()
      return context.context
    end
  end)

  after_each(function()
    context.delta_context = original_delta_context
  end)

  it('returns a parts array with prompt as first part', function()
    local parts = context.format_message('hello world'):wait()
    assert.is_table(parts)
    assert.equal('hello world', parts[1].text)
    assert.equal('text', parts[1].type)
  end)
  it('includes mentioned_files and subagents', function()
    context.context.mentioned_files = { '/tmp/foo.lua' }
    context.context.mentioned_subagents = { 'agent1' }
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
end)

describe('delta_context', function()
  it('removes current_file if unchanged', function()
    local file = { name = 'foo.lua', path = '/tmp/foo.lua', extension = 'lua' }
    context.context.current_file = vim.deepcopy(file)
    state.last_sent_context = { current_file = context.context.current_file }
    local result = context.delta_context()
    assert.is_nil(result.current_file)
  end)
  it('removes mentioned_subagents if unchanged', function()
    local subagents = { 'a' }
    context.context.mentioned_subagents = vim.deepcopy(subagents)
    state.last_sent_context = { mentioned_subagents = vim.deepcopy(subagents) }
    local result = context.delta_context()
    assert.is_nil(result.mentioned_subagents)
  end)
end)

describe('add_file/add_selection/add_subagent', function()
  before_each(function()
    context.context.mentioned_files = nil
    context.context.selections = nil
    context.delta_context()
    context.context.mentioned_subagents = nil
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
    assert.same({ '/tmp/foo.lua' }, context.context.mentioned_files)

    util.is_path_in_cwd = original_is_path_in_cwd
  end)
  it('does not add file if not filereadable', function()
    vim.fn.filereadable = function()
      return 0
    end
    context.add_file('/tmp/bar.lua')
    assert.same({}, context.context.mentioned_files)
  end)
  it('adds a selection', function()
    context.add_selection({ foo = 'bar' })
    assert.same({ { foo = 'bar' } }, context.context.selections)
  end)
  it('adds a subagent', function()
    context.add_subagent('agentX')
    assert.same({ 'agentX' }, context.context.mentioned_subagents)
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
