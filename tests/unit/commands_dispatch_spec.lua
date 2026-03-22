local assert = require('luassert')
local command_dispatch = require('opencode.commands.dispatch')
local command_parse = require('opencode.commands.parse')
local commands = require('opencode.commands')
local config = require('opencode.config')
local state = require('opencode.state')

describe('opencode.commands.dispatch', function()
  local original_hooks
  local original_event_manager

  local function includes(values, expected)
    for _, value in ipairs(values) do
      if value == expected then
        return true
      end
    end
    return false
  end

  ---@param overrides? table
  ---@return OpencodeCommandParseResult
  local function make_parsed(overrides)
    local defaults = {
      ok = true,
      intent = {
        command_id = 'test_cmd',
        execute = function() return 'ok' end,
        args = {},
        range = nil,
      },
    }
    return vim.tbl_deep_extend('force', defaults, overrides or {})
  end

  before_each(function()
    original_hooks = config.hooks
    original_event_manager = state.event_manager
    config.hooks = vim.deepcopy(config.hooks or {})
    state.jobs.set_event_manager(nil)
  end)

  after_each(function()
    config.hooks = original_hooks
    state.jobs.set_event_manager(original_event_manager)
  end)

  it('normalizes parse errors as fail result', function()
    local parsed = command_parse.command({ args = 'not_real', range = 0 }, commands.get_commands())

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_false(result.ok)
    assert.same({
      code = 'unknown_subcommand',
      message = 'Unknown subcommand: not_real',
      subcommand = 'not_real',
    }, result.error)
    assert.is_nil(result.intent)
  end)

  it('normalizes successful execution with intent and result', function()
    local parsed = make_parsed({
      intent = {
        command_id = 'toggle',
        execute = function() return 'done' end,
        args = {},
      },
    })

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_true(result.ok)
    assert.equal('done', result.result)
    assert.equal('toggle', result.intent.command_id)
    assert.same({}, result.intent.args)
  end)

  it('normalizes handler argument errors as fail result', function()
    local parsed = command_parse.command({ args = 'revert all', range = 0 }, commands.get_commands())

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_false(result.ok)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid revert target. Use: prompt, session, or <snapshot_id>',
    }, result.error)
    assert.equal('revert', result.intent.command_id)
  end)

  it('runs before -> execute -> after lifecycle in order', function()
    local events = {}

    local parsed = make_parsed({
      intent = {
        command_id = 'toggle',
        execute = function()
          table.insert(events, 'execute')
          return 'ok'
        end,
      },
    })

    config.hooks.on_command_before = function()
      table.insert(events, 'before')
    end
    config.hooks.on_command_after = function()
      table.insert(events, 'after')
    end
    config.hooks.on_command_finally = function()
      table.insert(events, 'finally')
    end

    local emitted = {}
    state.jobs.set_event_manager({
      emit = function(_, event_name, _)
        table.insert(emitted, event_name)
      end,
    })

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_true(result.ok)
    assert.same({ 'before', 'execute', 'after', 'finally' }, events)
    assert.is_true(includes(emitted, 'custom.command.before'))
    assert.is_true(includes(emitted, 'custom.command.after'))
    assert.is_true(includes(emitted, 'custom.command.finally'))
  end)

  it('triggers error and finally when execute throws', function()
    local stages = {}

    local parsed = make_parsed({
      intent = {
        command_id = 'toggle',
        execute = function()
          error({ code = 'execute_error', message = 'boom' }, 0)
        end,
      },
    })

    config.hooks.on_command_error = function()
      table.insert(stages, 'error')
    end
    config.hooks.on_command_finally = function()
      table.insert(stages, 'finally')
    end

    local emitted = {}
    state.jobs.set_event_manager({
      emit = function(_, event_name, _)
        table.insert(emitted, event_name)
      end,
    })

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_false(result.ok)
    assert.same({ 'error', 'finally' }, stages)
    assert.is_true(includes(emitted, 'custom.command.before'))
    assert.is_true(includes(emitted, 'custom.command.error'))
    assert.is_true(includes(emitted, 'custom.command.finally'))
  end)

  it('isolates hook errors from main dispatch flow', function()
    local emitted = {}

    local parsed = make_parsed({
      intent = {
        command_id = 'toggle',
        execute = function() return 'ok' end,
      },
    })

    state.jobs.set_event_manager({
      emit = function(_, event_name, _)
        table.insert(emitted, event_name)
      end,
    })

    config.hooks.on_command_before = function()
      error('hook boom')
    end
    config.hooks.on_command_after = function()
      error('hook boom')
    end
    config.hooks.on_command_finally = function()
      error('hook boom')
    end

    local result = command_dispatch.dispatch_intent(parsed)

    assert.is_true(result.ok)
    assert.equal('ok', result.result)
    assert.is_true(includes(emitted, 'custom.command.before'))
    assert.is_true(includes(emitted, 'custom.command.after'))
    assert.is_true(includes(emitted, 'custom.command.finally'))
    assert.is_true(includes(emitted, 'custom.command.hook_error'))
  end)
end)
