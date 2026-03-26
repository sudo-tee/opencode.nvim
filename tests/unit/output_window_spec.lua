local config = require('opencode.config')
local state = require('opencode.state')
local output_window = require('opencode.ui.output_window')
local stub = require('luassert.stub')

describe('output_window.create_buf', function()
  local original_config

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.values = vim.deepcopy(config.defaults)
  end)

  after_each(function()
    config.values = original_config
  end)

  it('uses default output filetype', function()
    config.setup({})
    local buf = output_window.create_buf()

    local filetype = vim.api.nvim_get_option_value('filetype', { buf = buf })
    assert.equals('opencode_output', filetype)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  it('uses configured output filetype', function()
    config.setup({
      ui = {
        output = {
          filetype = 'markdown',
        },
      },
    })

    local buf = output_window.create_buf()
    local filetype = vim.api.nvim_get_option_value('filetype', { buf = buf })

    assert.equals('markdown', filetype)

    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)
end)

describe('output_window.highlight_changed_lines', function()
  local original_config
  local buf
  local defer_stub
  local scheduled_cb

before_each(function()
  original_config = vim.deepcopy(config.values)
  config.values = vim.deepcopy(config.defaults)
  buf = vim.api.nvim_create_buf(false, true)
  state.ui.set_windows({ output_buf = buf })
  vim.api.nvim_buf_clear_namespace(buf, output_window.debug_namespace, 0, -1)
  scheduled_cb = nil
  defer_stub = stub(vim, 'defer_fn').invokes(function(cb)
    scheduled_cb = cb
    return 1
  end)
  end)

  after_each(function()
    if defer_stub then
      defer_stub:revert()
    end
    state.ui.set_windows(nil)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
    config.values = original_config
  end)

  it('adds and clears debug line highlights when enabled', function()
    config.setup({
      debug = {
        highlight_changed_lines = true,
        highlight_changed_lines_timeout_ms = 500,
      },
    })

    output_window.highlight_changed_lines(0, 1)

    local marks = vim.api.nvim_buf_get_extmarks(buf, output_window.debug_namespace, 0, -1, { details = true })
    assert.equals(2, #marks)
    assert.equals('OpencodeChangedLines', marks[1][4].line_hl_group)
    assert.is_function(scheduled_cb)

    scheduled_cb()

    local cleared = vim.api.nvim_buf_get_extmarks(buf, output_window.debug_namespace, 0, -1, {})
    assert.equals(0, #cleared)
  end)

  it('does nothing when debug highlights are disabled', function()
    config.setup({
      debug = {
        highlight_changed_lines = false,
      },
    })

    output_window.highlight_changed_lines(0, 1)

    local marks = vim.api.nvim_buf_get_extmarks(buf, output_window.debug_namespace, 0, -1, {})
    assert.equals(0, #marks)
  end)
end)

describe('output_window namespaces', function()
  it('exposes a dedicated markdown namespace', function()
    assert.is_number(output_window.markdown_namespace)
    assert.is_not.equals(output_window.namespace, output_window.markdown_namespace)
    assert.is_not.equals(output_window.debug_namespace, output_window.markdown_namespace)
  end)
end)
