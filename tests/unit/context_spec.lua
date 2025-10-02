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
    local parts = context.format_message('hello world')
    assert.is_table(parts)
    assert.equal('hello world', parts[1].text)
    assert.equal('text', parts[1].type)
  end)
  it('includes mentioned_files and subagents', function()
    context.context.mentioned_files = { '/tmp/foo.lua' }
    context.context.mentioned_subagents = { 'agent1' }
    local parts = context.format_message('prompt @foo.lua @agent1')
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
    context.add_file('/tmp/foo.lua')
    assert.same({ '/tmp/foo.lua' }, context.context.mentioned_files)
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

describe('get_marks', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.marks = { enabled = true, limit = 10 }
  end)
  it('returns nil when disabled', function()
    config.values.context.marks.enabled = false
    local result = context.get_marks()
    assert.is_nil(result)
  end)
  it('returns marks when enabled', function()
    vim.fn.getmarklist = function()
      return {
        { mark = "'a", pos = { 1, 10, 5, 0 }, file = '/tmp/test.lua' },
        { mark = "'b", pos = { 1, 20, 10, 0 } },
      }
    end
    local result = context.get_marks()
    assert.is_table(result)
    assert.equal(2, #result)
    assert.equal("'a", result[1].mark)
    assert.equal(10, result[1].line)
  end)
end)

describe('get_jumplist', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.jumplist = { enabled = true, limit = 10 }
  end)
  it('returns nil when disabled', function()
    config.values.context.jumplist.enabled = false
    local result = context.get_jumplist()
    assert.is_nil(result)
  end)
  it('returns jumplist when enabled', function()
    vim.fn.getjumplist = function()
      return { { bufnr = 1, lnum = 10, col = 5 }, { bufnr = 2, lnum = 20, col = 10 } }, 1
    end
    vim.fn.bufname = function(bufnr)
      return '/tmp/file' .. bufnr .. '.lua'
    end
    local result = context.get_jumplist()
    assert.is_table(result)
    assert.is_table(result.jumps)
    assert.equal(1, result.current)
  end)
end)

describe('get_recent_buffers', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.recent_buffers = { enabled = true, limit = 10 }
  end)
  it('returns nil when disabled', function()
    config.values.context.recent_buffers.enabled = false
    local result = context.get_recent_buffers()
    assert.is_nil(result)
  end)
  it('returns recent buffers when enabled', function()
    vim.fn.getbufinfo = function()
      return {
        { bufnr = 1, name = '/tmp/file1.lua', lastused = 1000, changed = 0 },
        { bufnr = 2, name = '/tmp/file2.lua', lastused = 2000, changed = 1 },
      }
    end
    local result = context.get_recent_buffers()
    assert.is_table(result)
    assert.equal(2, #result)
    assert.equal(2000, result[1].lastused)
  end)
end)

describe('get_command_history', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.command_history = { enabled = true, limit = 5 }
  end)
  it('returns nil when disabled', function()
    config.values.context.command_history.enabled = false
    local result = context.get_command_history()
    assert.is_nil(result)
  end)
  it('returns command history when enabled', function()
    local commands = { 'echo 1', 'echo 2', 'echo 3' }
    local idx = 1
    vim.fn.histget = function(type, i)
      if i < 0 then
        local pos = #commands + i + 1
        return commands[pos] or ''
      end
      return ''
    end
    local result = context.get_command_history()
    assert.is_table(result)
  end)
end)

describe('get_search_history', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.search_history = { enabled = true, limit = 5 }
  end)
  it('returns nil when disabled', function()
    config.values.context.search_history.enabled = false
    local result = context.get_search_history()
    assert.is_nil(result)
  end)
  it('returns search history when enabled', function()
    local searches = { 'foo', 'bar', 'baz' }
    vim.fn.histget = function(type, i)
      if type == '/' and i < 0 then
        local pos = #searches + i + 1
        return searches[pos] or ''
      end
      return ''
    end
    local result = context.get_search_history()
    assert.is_table(result)
  end)
end)

describe('get_session_duration', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.session_duration = { enabled = true }
  end)
  it('returns nil when disabled', function()
    config.values.context.session_duration.enabled = false
    local result = context.get_session_duration()
    assert.is_nil(result)
  end)
  it('returns session duration when enabled', function()
    local result = context.get_session_duration()
    assert.is_table(result)
    assert.is_number(result.duration_seconds)
    assert.is_number(result.duration_minutes)
    assert.is_number(result.duration_hours)
  end)
end)

describe('get_registers', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.registers = { enabled = true, include = { '"', '/', 'q' } }
  end)
  it('returns nil when disabled', function()
    config.values.context.registers.enabled = false
    local result = context.get_registers()
    assert.is_nil(result)
  end)
  it('returns registers when enabled', function()
    vim.fn.getreginfo = function(reg)
      return { regcontents = { 'line1', 'line2' }, regtype = 'V' }
    end
    local result = context.get_registers()
    assert.is_table(result)
  end)
end)

describe('get_macros', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.macros = { enabled = true, register = 'q' }
  end)
  it('returns nil when disabled', function()
    config.values.context.macros.enabled = false
    local result = context.get_macros()
    assert.is_nil(result)
  end)
  it('returns macro when enabled and register has content', function()
    vim.fn.getreg = function(reg)
      if reg == 'q' then
        return 'iHello<Esc>'
      end
      return ''
    end
    local result = context.get_macros()
    assert.is_table(result)
    assert.equal('q', result.register)
    assert.equal('iHello<Esc>', result.content)
  end)
  it('returns nil when register is empty', function()
    vim.fn.getreg = function()
      return ''
    end
    local result = context.get_macros()
    assert.is_nil(result)
  end)
end)

describe('get_git_info', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.git_info = { enabled = true, diff_limit = 10, changes_limit = 5 }
  end)
  it('returns nil when disabled', function()
    config.values.context.git_info.enabled = false
    local result = context.get_git_info()
    assert.is_nil(result)
  end)
  it('returns git info when in a git repo', function()
    vim.fn.systemlist = function(cmd)
      if cmd:match('rev%-parse') then
        return { 'main' }
      elseif cmd:match('log') then
        return { 'abc123 commit 1', 'def456 commit 2' }
      end
      return {}
    end
    local result = context.get_git_info()
    if result then
      assert.is_table(result)
      assert.equal('main', result.branch)
    end
  end)
end)

describe('format_message with new context types', function()
  local config = require('opencode.config')
  local original_delta_context
  before_each(function()
    context.context.marks = { { mark = "'a", line = 10, col = 5 } }
    context.context.jumplist = { jumps = {}, current = 0 }
    context.context.session_duration = { duration_seconds = 120 }
    original_delta_context = context.delta_context
    context.delta_context = function()
      return context.context
    end
  end)

  after_each(function()
    context.delta_context = original_delta_context
    context.context.marks = nil
    context.context.jumplist = nil
    context.context.session_duration = nil
  end)

  it('includes new context types in message parts', function()
    local parts = context.format_message('test prompt')
    assert.is_table(parts)
    -- Should have prompt + new context types
    assert.is_true(#parts >= 1)
    -- Check for synthetic context parts
    local found_context = false
    for _, part in ipairs(parts) do
      if part.synthetic and part.text then
        local ok, decoded = pcall(vim.json.decode, part.text)
        if ok and decoded.context_type then
          found_context = true
          break
        end
      end
    end
    assert.is_true(found_context)
  end)

describe('get_recent_buffers with symbols', function()
  local config = require('opencode.config')
  before_each(function()
    config.values.context.recent_buffers = { enabled = true, limit = 1, symbols_only = false }
    vim.fn.getbufinfo = function()
      return { { bufnr = 1, name = '/tmp/file.lua', lastused = 1000, changed = 0 } }
    end
  end)

  it('does not include symbols when symbols_only is false', function()
    local result = context.get_recent_buffers()
    assert.is_nil(result[1].symbols)
  end)

  it('includes symbols when symbols_only enabled and constraints met', function()
    config.values.context.recent_buffers.symbols_only = true
    vim.api.nvim_buf_line_count = function() return 150 end
    vim.lsp.get_active_clients = function() return { { name = 'lua_ls' } } end
    vim.api.nvim_buf_get_option = function(_, opt) return opt == "readonly" and false end
    vim.bo = { [1] = { buftype = '' } }
    local mock_resp = {
      [1] = {
        result = {
          {
            name = 'setup',
            kind = 6,  -- Function
            range = { start = {1, 0}, ['end'] = {5, 0} },
            detail = 'setup function'
          }
        }
      }
    }
    vim.lsp.buf_request_sync = function(_, _, _, _) return mock_resp end
    local result = context.get_recent_buffers()
    assert.is_table(result[1].symbols)
    assert.equal(1, #result[1].symbols)
    assert.equal('setup', result[1].symbols[1].name)
  end)

  it('skips symbols if line count <= 100', function()
    config.values.context.recent_buffers.symbols_only = true
    vim.api.nvim_buf_line_count = function() return 50 end
    local result = context.get_recent_buffers()
    assert.is_nil(result[1].symbols)
  end)

  it('skips symbols if no LSP attached', function()
    config.values.context.recent_buffers.symbols_only = true
    vim.api.nvim_buf_line_count = function() return 150 end
    vim.lsp.get_active_clients = function() return {} end
    local result = context.get_recent_buffers()
    assert.is_nil(result[1].symbols)
  end)

  it('skips symbols if buffer is readonly', function()
    config.values.context.recent_buffers.symbols_only = true
    vim.api.nvim_buf_line_count = function() return 150 end
    vim.lsp.get_active_clients = function() return { {} } end
    vim.api.nvim_buf_get_option = function(_, opt) return opt == "readonly" and true end
    local result = context.get_recent_buffers()
    assert.is_nil(result[1].symbols)
  end)

  it('skips symbols if buffer is terminal', function()
    config.values.context.recent_buffers.symbols_only = true
    vim.api.nvim_buf_line_count = function() return 150 end
    vim.lsp.get_active_clients = function() return { {} } end
    vim.api.nvim_buf_get_option = function(_, opt) return false end
    vim.bo = { [1] = { buftype = 'terminal' } }
    local result = context.get_recent_buffers()
    assert.is_nil(result[1].symbols)
  end)
end)

end)
