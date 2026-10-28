local assert = require('luassert')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local opencode = require('opencode')
local registry = require('opencode.ui.formatter.tool_registry')

describe('custom tool formatters', function()
  local registered = {}
  local original_config

  local function register(name, tool_formatter, opts)
    opencode.register_tool_formatter(name, tool_formatter, opts)
    table.insert(registered, name)
  end

  local function render(name, fields)
    local part = vim.tbl_extend('force', {
      id = 'prt_tool_formatter',
      kind = 'tool',
      name = name,
      state = 'completed',
      input = {},
    }, fields or {})
    return formatter.format_part(part, {
      id = 'msg_tool_formatter',
      session_id = 'ses_tool_formatter',
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
            use_folds = false,
          },
        },
      },
    })
  end)

  after_each(function()
    for _, name in ipairs(registered) do
      opencode.unregister_tool_formatter(name)
    end
    registered = {}
    config.values = original_config
  end)

  it('exposes tool formatter registration in the public API', function()
    assert.is_function(opencode.register_tool_formatter)
    assert.is_function(opencode.unregister_tool_formatter)
  end)

  it('renders a custom tool through its registered formatter', function()
    register('ci_report', {
      format = function(output, part)
        output:add_line('CI report for ' .. part.input.branch)
      end,
    })

    local output = render('ci_report', { input = { branch = 'main' } })

    assert.is_truthy(text(output):find('CI report for main', 1, true))
  end)

  it('rejects empty names', function()
    assert.has_error(function()
      opencode.register_tool_formatter('', { format = function() end })
    end)
  end)

  it('rejects duplicate custom formatters', function()
    register('ci_report', { format = function() end })

    assert.has_error(function()
      opencode.register_tool_formatter('ci_report', { format = function() end })
    end)
    assert.has_error(function()
      opencode.register_tool_formatter('ci_report', { format = function() end }, { replace = true })
    end)
  end)

  it('requires an explicit opt-in to replace a built-in formatter', function()
    assert.has_error(function()
      opencode.register_tool_formatter('bash', { format = function() end })
    end)
  end)

  it('restores the built-in formatter after unregistering an override', function()
    register('bash', {
      format = function(output)
        output:add_line('CUSTOM BASH')
      end,
    }, { replace = true })

    local overridden = render('bash', { command = 'echo hi' })
    assert.is_truthy(text(overridden):find('CUSTOM BASH', 1, true))

    assert.is_true(opencode.unregister_tool_formatter('bash'))
    assert.is_false(opencode.unregister_tool_formatter('bash'))

    local restored = render('bash', { command = 'echo hi' })
    assert.is_nil(text(restored):find('CUSTOM BASH', 1, true))
    assert.is_truthy(text(restored):find('run', 1, true))
  end)

  it('falls back to the built-in formatter when an override fails', function()
    local original_log = package.loaded['opencode.log']
    local logged
    package.loaded['opencode.log'] = {
      error = function(message, ...)
        logged = string.format(message, ...)
      end,
    }
    register('bash', {
      format = function(output)
        output:add_line('PARTIAL OUTPUT')
        error('formatter exploded')
      end,
    }, { replace = true })

    local output = render('bash', { command = 'echo hi' })
    package.loaded['opencode.log'] = original_log

    assert.is_nil(text(output):find('PARTIAL OUTPUT', 1, true))
    assert.is_truthy(text(output):find('run', 1, true))
    assert.is_truthy(logged:find('bash', 1, true))
  end)

  it('renders a custom tool while its input is still streaming', function()
    register('deploy_status', {
      format = function(output, part)
        local service = (part.input and part.input.service) or part.input_text or part.state
        output:add_line('deploy: ' .. service)
      end,
    })

    local part = {
      id = 'prt_streaming_tool',
      kind = 'tool',
      name = 'deploy_status',
      state = 'streaming',
      input_text = '{"service":"api',
    }
    local output = formatter.format_part(part, {
      id = 'msg_streaming_tool',
      session_id = 'ses_tool_formatter',
      kind = 'assistant',
      content = { part },
    }, true)

    assert.is_truthy(text(output):find('deploy: {"service":"api', 1, true))
  end)

  it('keeps core error rendering and fold policy for custom formatters', function()
    config.ui.output.tools.use_folds = true
    config.ui.output.tools.fold_exclude = { 'ci_report' }
    register('ci_report', {
      format = function(output)
        output:add_line('line one')
        output:add_line('line two')
        output:add_line('line three')
        output:add_fold(1, 3)
      end,
    })

    local output = render('ci_report', {
      state = 'error',
      error = { message = 'tests failed' },
    })

    assert.same({}, output.fold_ranges)
    assert.is_truthy(text(output):find('tests failed', 1, true))
  end)

  it('uses a custom summary for nested tool rows and keeps built-in summaries otherwise', function()
    local custom_summary = function()
      return 'icon', 'ci', 'report'
    end
    register('ci_report', {
      format = function() end,
      summary = custom_summary,
    })
    assert.same({ 'icon', 'ci', 'report' }, { registry.summary('ci_report')({}) })

    register('grep', {
      format = function() end,
    }, { replace = true })
    assert.are.equal(require('opencode.ui.formatter.tools.grep').summary, registry.summary('grep'))
  end)

  it('falls back to the built-in summary when a custom summary fails', function()
    local original_log = package.loaded['opencode.log']
    local logged
    package.loaded['opencode.log'] = {
      error = function(message, ...)
        logged = string.format(message, ...)
      end,
    }
    register('grep', {
      format = function() end,
      summary = function()
        error('summary exploded')
      end,
    }, { replace = true })

    local part = { name = 'grep', state = 'completed', input = { pattern = 'x' } }
    local expected = { require('opencode.ui.formatter.tools.grep').summary(part) }
    local actual = { registry.summary('grep')(part) }
    package.loaded['opencode.log'] = original_log

    assert.same(expected, actual)
    assert.is_truthy(logged:find('summary exploded', 1, true))
  end)

  it('logs formatter errors containing format specifiers', function()
    local original_log = package.loaded['opencode.log']
    local logged
    package.loaded['opencode.log'] = {
      error = function(message, ...)
        logged = string.format(message, ...)
      end,
    }
    register('bash', {
      format = function()
        error('bad pattern %d %y')
      end,
    }, { replace = true })

    local output = render('bash', { command = 'echo hi' })
    package.loaded['opencode.log'] = original_log

    assert.is_truthy(text(output):find('run', 1, true))
    assert.is_truthy(logged:find('bad pattern %d %y', 1, true))
  end)
end)
