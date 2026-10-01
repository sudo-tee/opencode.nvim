local assert = require('luassert')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')

describe('shared tool-result rendering', function()
  local original_config

  local function render(name, fields)
    local part = vim.tbl_extend('force', {
      id = 'prt_result',
      kind = 'tool',
      name = name,
      state = 'completed',
    }, fields or {})
    return formatter.format_part(part, {
      id = 'msg_result',
      session_id = 'ses_result',
      kind = 'assistant',
      content = { part },
    }, true)
  end

  local function text(output)
    return table.concat(output.lines, '\n')
  end

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.setup({
      ui = {
        output = {
          tools = {
            show_output = true,
            use_folds = true,
            folding_threshold = 2,
            fold_exclude = {},
          },
        },
      },
    })
  end)

  after_each(function()
    config.values = original_config
  end)

  for _, name in ipairs({ 'execute', 'custom', 'server_lookup', 'browser.tabs.list', 'opencode.session_move' }) do
    it('renders ordered text and attachment results for ' .. name, function()
      local output = render(name, {
        input = { code = 'return 42', query = 'find files' },
        result = {
          { kind = 'text', text = 'First result\nMore text' },
          { kind = 'file', uri = 'file:///tmp/result%20file.txt', name = 'result file.txt', media_type = 'text/plain' },
          { kind = 'text', text = 'Last result' },
        },
      })
      local rendered = text(output)
      local first = assert(rendered:find('First result\nMore text', 1, true))
      local attachment = assert(rendered:find('Attachment:', 1, true))
      local last = assert(rendered:find('Last result', 1, true))
      assert.is_true(first < attachment and attachment < last)
      assert.same('file', output.targets[1].kind)
      assert.same('/tmp/result file.txt', output.targets[1].path)
      assert.is_truthy(output.lines[output.targets[1].range.line]:find('result file.txt', 1, true))
      assert.is_true(#output.fold_ranges > 0)
    end)
  end

  it('keeps execute code and results in separate folds', function()
    config.ui.output.tools.show_output = false
    local output = render('execute', {
      input = { code = 'return 42' },
      result = { { kind = 'text', text = '42' } },
    })
    assert.equals(2, #output.fold_ranges)
    assert.is_true(output.fold_ranges[1].to < output.fold_ranges[2].from)
    assert.equals('**Result**', output.lines[output.fold_ranges[2].from])
  end)

  it('renders generic input as JSON without requiring a result', function()
    local output = render('custom', { input = { enabled = true, nested = { value = 42 } }, state = 'running' })
    assert.is_truthy(text(output):find('**Input**', 1, true))
    assert.is_truthy(text(output):find('`````json', 1, true))
    assert.is_truthy(text(output):find('"value":42', 1, true))
    assert.is_falsy(text(output):find('**Result**', 1, true))
  end)

  it('adds HTTP attachment targets', function()
    local output = render('custom', {
      result = {
        { kind = 'file', uri = 'https://example.com/result.pdf', name = 'Report', media_type = 'application/pdf' },
      },
    })
    assert.equals('uri', output.targets[1].kind)
    assert.equals('https://example.com/result.pdf', output.targets[1].uri)
    assert.is_truthy(text(output):find('[Report](<https://example.com/result.pdf>)', 1, true))
  end)

  it('labels inline attachments without displaying base64 payloads', function()
    local output = render('custom', {
      result = {
        { kind = 'file', uri = 'data:image/png;base64,SECRET_PAYLOAD', media_type = 'image/png' },
      },
    })
    assert.is_truthy(text(output):find('Inline attachment (image/png)', 1, true))
    assert.is_falsy(text(output):find('SECRET_PAYLOAD', 1, true))
    assert.same({}, output.targets)
  end)

  it('omits empty result sections', function()
    for _, result in ipairs({ {}, { { kind = 'text', text = '' } } }) do
      local output = render('custom', { input = {}, result = result })
      assert.is_falsy(text(output):find('**Input**', 1, true))
      assert.is_falsy(text(output):find('**Result**', 1, true))
      assert.same({}, output.fold_ranges)
    end
  end)

  it('hides input and results when output and folds are disabled', function()
    config.ui.output.tools.show_output = false
    config.ui.output.tools.use_folds = false
    for _, name in ipairs({ 'execute', 'custom', 'server_lookup' }) do
      local output = render(name, {
        input = { code = 'HIDDEN_INPUT', query = 'HIDDEN_INPUT' },
        result = { { kind = 'text', text = 'HIDDEN_RESULT' } },
      })
      assert.is_falsy(text(output):find('HIDDEN_', 1, true))
      assert.same({}, output.fold_ranges)
    end
  end)

  it('honors fold exclusions for input and result sections', function()
    config.ui.output.tools.show_output = false
    config.ui.output.tools.fold_exclude = { 'execute', 'custom', { server = 'server', tool = 'lookup' } }
    for _, name in ipairs({ 'execute', 'custom', 'server_lookup' }) do
      local output = render(name, {
        input = { code = 'return 42', query = 'find files' },
        result = { { kind = 'text', text = 'Visible result' } },
      })
      assert.same({}, output.fold_ranges)
      assert.is_truthy(text(output):find('Visible result', 1, true))
    end
  end)

  it('keeps errors visible outside result folds', function()
    config.ui.output.tools.show_output = false
    local output = render('custom', {
      state = 'error',
      result = { { kind = 'text', text = 'Partial result' } },
      error = { message = 'Tool failed' },
    })
    assert.is_truthy(text(output):find('Tool failed', 1, true))
    assert.is_true(output.fold_ranges[1].to < #output.lines - 1)
  end)
end)
