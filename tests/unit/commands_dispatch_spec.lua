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
        name = 'toggle',
        execute = function() return 'ok' end,
        args = {},
        range = nil,
        source = {
          raw_args = 'toggle',
          argv = { 'toggle' },
        },
      },
    }
    return vim.tbl_deep_extend('force', defaults, overrides or {})
  end

  ---@param parsed OpencodeCommandParseResult
  ---@param execute_override? fun(args: string[], range: OpencodeSelectionRange|nil): any
  ---@return OpencodeCommandActionContext
  local function make_ctx(parsed, execute_override)
    return commands.bind_action_context(parsed, execute_override)
  end

  before_each(function()
    original_hooks = config.hooks
    original_event_manager = state.event_manager
    config.hooks = vim.deepcopy(config.hooks or {})
    state.jobs.set_event_manager(nil)
    command_dispatch.reset_hooks_for_test()
  end)

  after_each(function()
    config.hooks = original_hooks
    state.jobs.set_event_manager(original_event_manager)
  end)

  it('normalizes parse errors as fail result', function()
    local parsed = command_parse.command({ args = 'not_real', range = 0 }, commands.get_commands())

    local result = command_dispatch.execute(make_ctx(parsed))

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
        name = 'toggle',
        execute = function() return 'done' end,
        args = {},
      },
    })

    local result = command_dispatch.execute(make_ctx(parsed, parsed.intent.execute))

    assert.is_true(result.ok)
    assert.equal('done', result.result)
    assert.equal('toggle', result.intent.name)
    assert.same({}, result.intent.args)
  end)

  it('normalizes handler argument errors as fail result', function()
    local parsed = command_parse.command({ args = 'revert all', range = 0 }, commands.get_commands())

    local result = command_dispatch.execute(make_ctx(parsed))

    assert.is_false(result.ok)
    assert.same({
      code = 'invalid_arguments',
      message = 'Invalid revert target. Use: prompt, session, or <snapshot_id>',
    }, result.error)
    assert.equal('revert', result.intent.name)
  end)

  it('fails with invalid_arguments when permission subcommand is unknown after bind', function()
    local parsed = make_parsed({
      intent = {
        name = 'permission',
        args = { 'unknown' },
        range = nil,
        source = {
          raw_args = 'permission unknown',
          argv = { 'permission', 'unknown' },
        },
      },
    })

    local result = command_dispatch.execute(make_ctx(parsed))

    assert.is_false(result.ok)
    assert.same('invalid_arguments', result.error.code)
    assert.same('Invalid permission subcommand. Use: accept, accept_all, or deny', result.error.message)
    assert.equal('permission', result.intent.name)
  end)

  it('runs before -> execute -> after lifecycle in order', function()
    local events = {}

    local parsed = make_parsed({
      intent = {
        name = 'toggle',
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

    local result = command_dispatch.execute(make_ctx(parsed, parsed.intent.execute))

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
        name = 'toggle',
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

    local result = command_dispatch.execute(make_ctx(parsed, parsed.intent.execute))

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
        name = 'toggle',
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

    local result = command_dispatch.execute(make_ctx(parsed, parsed.intent.execute))

    assert.is_true(result.ok)
    assert.equal('ok', result.result)
    assert.is_true(includes(emitted, 'custom.command.before'))
    assert.is_true(includes(emitted, 'custom.command.after'))
    assert.is_true(includes(emitted, 'custom.command.finally'))
    assert.is_true(includes(emitted, 'custom.command.hook_error'))
  end)

  it('applies runtime hook command filters and supports unregister', function()
    local seen = {}
    local hook_id = command_dispatch.register_hook('before', function(ctx)
      table.insert(seen, ctx.intent.name)
      return ctx
    end, { command = 'run' })

    local toggle_parsed = make_parsed({
      intent = {
        name = 'toggle',
        execute = function() return 'toggle' end,
      },
    })
    local run_parsed = make_parsed({
      intent = {
        name = 'run',
        execute = function() return 'run' end,
      },
    })

    local toggle_result = command_dispatch.execute(make_ctx(toggle_parsed, toggle_parsed.intent.execute))
    local run_result = command_dispatch.execute(make_ctx(run_parsed, run_parsed.intent.execute))

    assert.is_true(toggle_result.ok)
    assert.is_true(run_result.ok)
    assert.same({ 'run' }, seen)

    assert.is_true(command_dispatch.unregister_hook('before', hook_id))
    local run_result_after_unregister = command_dispatch.execute(make_ctx(run_parsed, run_parsed.intent.execute))
    assert.is_true(run_result_after_unregister.ok)
    assert.same({ 'run' }, seen)
  end)

  it('supports hook filter fallback from hook_key to intent name', function()
    local seen = {}

    command_dispatch.register_hook('before', function(ctx)
      table.insert(seen, 'group:' .. ctx.intent.name)
      return ctx
    end, { command = 'session' })

    command_dispatch.register_hook('before', function(ctx)
      table.insert(seen, 'name:' .. ctx.intent.name)
      return ctx
    end, { command = 'select_session' })

    local parsed = make_parsed({
      intent = {
        name = 'select_session',
        hook_key = 'session',
        execute = function() return 'ok' end,
      },
    })

    local result = command_dispatch.execute(make_ctx(parsed, parsed.intent.execute))
    assert.is_true(result.ok)
    assert.same({ 'group:select_session', 'name:select_session' }, seen)
  end)

end)
