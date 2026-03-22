-- TODO: hooks pipeline is wired but not yet exposed in config defaults.
-- Future: add on_command_before/after/error/finally to config.hooks so users
-- can intercept commands. The custom.command.* events will also need subscribers.
-- See docs/explorations/hooks-system.md for design intent.
local config = require('opencode.config')
local state = require('opencode.state')

local M = {}

local lifecycle_hook_keys = {
  before = 'on_command_before',
  after = 'on_command_after',
  error = 'on_command_error',
  finally = 'on_command_finally',
}

local lifecycle_event_names = {
  before = 'custom.command.before',
  after = 'custom.command.after',
  error = 'custom.command.error',
  finally = 'custom.command.finally',
}

---@param event_name string
---@param payload table
local function emit_lifecycle_event(event_name, payload)
  local manager = state.event_manager
  if manager and type(manager.emit) == 'function' then
    pcall(manager.emit, manager, event_name, payload)
  end
end

---@param stage OpencodeCommandLifecycleStage
---@param hook_id string
---@param hook_fn OpencodeCommandDispatchHook
---@param ctx OpencodeCommandDispatchContext
---@return OpencodeCommandDispatchContext
local function run_hook(stage, hook_id, hook_fn, ctx)
  local ok, next_ctx_or_err = pcall(hook_fn, ctx)
  if not ok then
    emit_lifecycle_event('custom.command.hook_error', {
      stage = stage,
      hook_id = hook_id,
      error = tostring(next_ctx_or_err),
      context = ctx,
    })
    return ctx
  end

  if type(next_ctx_or_err) == 'table' then
    return next_ctx_or_err
  end

  return ctx
end

---@param stage OpencodeCommandLifecycleStage
---@param ctx OpencodeCommandDispatchContext
---@return OpencodeCommandDispatchContext
local function run_hook_pipeline(stage, ctx)
  local next_ctx = ctx

  local hooks = config.hooks
  if hooks then
    local config_hook_name = lifecycle_hook_keys[stage]
    local config_hook = hooks[config_hook_name]
    if type(config_hook) == 'function' then
      next_ctx = run_hook(stage, 'config:' .. config_hook_name, config_hook, next_ctx)
    end
  end

  emit_lifecycle_event(lifecycle_event_names[stage], next_ctx)

  return next_ctx
end

---@param parsed OpencodeCommandParseResult
---@return OpencodeCommandDispatchResult
function M.dispatch_intent(parsed)
  ---@type OpencodeCommandDispatchContext
  local ctx = {
    parsed = parsed,
    intent = parsed.intent,
    args = parsed.intent and parsed.intent.args or nil,
    range = parsed.intent and parsed.intent.range or nil,
  }

  if not parsed.ok then
    ctx.error = {
      code = parsed.error.code,
      message = parsed.error.message,
      subcommand = parsed.error.subcommand,
    }
    ctx = run_hook_pipeline('error', ctx)
    ctx = run_hook_pipeline('finally', ctx)

    return {
      ok = false,
      error = ctx.error,
    }
  end

  ctx = run_hook_pipeline('before', ctx)

  local intent = ctx.intent or parsed.intent
  if not intent then
    ctx.error = {
      code = 'missing_handler',
      message = 'Missing command intent',
    }
    ctx = run_hook_pipeline('error', ctx)
    ctx = run_hook_pipeline('finally', ctx)

    return {
      ok = false,
      error = ctx.error,
    }
  end

  local args = ctx.args or intent.args or {}
  local range = ctx.range or intent.range
  intent.args = args
  intent.range = range
  ctx.intent = intent

  local execute_fn = intent.execute
  if not execute_fn then
    ctx.error = {
      code = 'missing_execute',
      message = 'Command has no execute function',
    }
    ctx = run_hook_pipeline('error', ctx)
    ctx = run_hook_pipeline('finally', ctx)

    return {
      ok = false,
      intent = ctx.intent,
      error = ctx.error,
    }
  end

  local ok, result_or_err = pcall(execute_fn, args, range)

  if not ok then
    local err = result_or_err
    if type(err) == 'table' and err.code then
      ctx.error = err
    else
      ctx.error = {
        code = 'execute_error',
        message = tostring(err),
      }
    end
    ctx = run_hook_pipeline('error', ctx)
    ctx = run_hook_pipeline('finally', ctx)

    return {
      ok = false,
      intent = ctx.intent,
      error = ctx.error,
    }
  end

  ctx.result = result_or_err
  ctx = run_hook_pipeline('after', ctx)
  ctx = run_hook_pipeline('finally', ctx)

  return {
    ok = true,
    result = ctx.result,
    intent = ctx.intent,
  }
end

return M
