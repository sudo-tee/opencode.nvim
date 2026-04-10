local config = require('opencode.config')
local log = require('opencode.log')
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

---@type table<OpencodeCommandLifecycleStage, { id: string, fn: OpencodeCommandDispatchHook, command_filter: table<string, true>|nil }[]>
local hook_registry = {
  before = {},
  after = {},
  error = {},
  finally = {},
}

local hook_sequence = 0

---@alias OpencodeCommandHookEntry { id: string, fn: OpencodeCommandDispatchHook, command_filter: table<string, true>|nil }

---@param command? string|string[]
---@return table<string, true>|nil
local function normalize_command_filter(command)
  if command == nil or command == '*' then
    return nil
  end

  if type(command) == 'string' then
    return { [command] = true }
  end

  if type(command) ~= 'table' then
    error('Hook command filter must be "*", string, or string[]')
  end

  local filter = {}
  for _, name in ipairs(command) do
    if name == '*' then
      return nil
    end
    if type(name) ~= 'string' or name == '' then
      error('Hook command filter entries must be non-empty strings')
    end
    filter[name] = true
  end

  if next(filter) == nil then
    error('Hook command filter list cannot be empty')
  end

  return filter
end

---@param entry { id: string, fn: OpencodeCommandDispatchHook, command_filter: table<string, true>|nil }
---@param ctx OpencodeCommandDispatchContext
---@return boolean
local function should_run_hook(entry, ctx)
  if entry.command_filter == nil then
    return true
  end

  local intent = ctx.intent
  local name = intent and intent.name or nil
  local hook_key = intent and intent.hook_key or nil
  if not name and not hook_key then
    return false
  end

  if hook_key and entry.command_filter[hook_key] == true then
    return true
  end

  return name and entry.command_filter[name] == true or false
end

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
    -- Keep observer failures isolated so command execution stays deterministic.
    local command_name = (ctx.intent and ctx.intent.name) or 'unknown'
    log.warn('event=command_hook_error command=%s stage=%s hook_id=%s error=%s', command_name, stage, hook_id, tostring(next_ctx_or_err))
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

  -- Contract: config hook runs first, runtime hooks run after it, then the stage event is emitted.
  -- This keeps hook ordering deterministic across all command entries.
  local config_hook_name = lifecycle_hook_keys[stage]
  local config_hook = config.hooks and config.hooks[config_hook_name]
  if type(config_hook) == 'function' then
    next_ctx = run_hook(stage, 'config:' .. config_hook_name, config_hook, next_ctx)
  end

  ---@type OpencodeCommandHookEntry[]
  for _, entry in ipairs(hook_registry[stage]) do
    if should_run_hook(entry, next_ctx) then
      next_ctx = run_hook(stage, entry.id, entry.fn, next_ctx)
    end
  end

  emit_lifecycle_event(lifecycle_event_names[stage], next_ctx)
  return next_ctx
end

-- Parse/bind failures may not have a stable intent yet; execute failures must carry intent for callers.
local failure_profiles = {
  parse = { fallback_code = 'invalid_arguments', fallback_message = 'Invalid command', include_intent = false },
  bind = { fallback_code = 'missing_handler', fallback_message = nil, include_intent = false },
  execute_missing = { fallback_code = 'missing_execute', fallback_message = nil, include_intent = true },
  execute_error = { fallback_code = 'execute_error', fallback_message = nil, include_intent = true },
}

---@param err any
---@param fallback_code? string
---@param fallback_message? string
---@return OpencodeCommandDispatchError
function M.normalize_error(err, fallback_code, fallback_message)
  local code = fallback_code or 'execute_error'

  if type(err) == 'table' then
    local normalized = {
      code = err.code or code,
      message = err.message,
    }

    if not normalized.message or normalized.message == '' then
      normalized.message = fallback_message or tostring(err)
    end

    if err.subcommand ~= nil then
      normalized.subcommand = err.subcommand
    end

    return normalized
  end

  return {
    code = code,
    message = tostring(err or fallback_message or 'Unknown command error'),
  }
end

---@param stage OpencodeCommandLifecycleStage
---@param hook_fn OpencodeCommandDispatchHook
---@param hook_id_or_opts? string|{ command?: string|string[] }
---@param hook_opts? { command?: string|string[] }
---@return string
function M.register_hook(stage, hook_fn, hook_id_or_opts, hook_opts)
  if not hook_registry[stage] then
    error('Unknown hook stage: ' .. tostring(stage))
  end
  if type(hook_fn) ~= 'function' then
    error('Hook must be a function')
  end

  local hook_id = nil
  local opts = hook_opts
  if type(hook_id_or_opts) == 'table' and hook_opts == nil then
    opts = hook_id_or_opts
  elseif hook_id_or_opts ~= nil then
    if type(hook_id_or_opts) ~= 'string' then
      error('Hook ID must be a string')
    end
    hook_id = hook_id_or_opts
  end

  hook_sequence = hook_sequence + 1
  local id = hook_id or ('dispatch:' .. stage .. ':' .. hook_sequence)
  local command_filter = normalize_command_filter(opts and opts.command)
  table.insert(hook_registry[stage], { id = id, fn = hook_fn, command_filter = command_filter })
  return id
end

---@param stage OpencodeCommandLifecycleStage
---@param hook_id string
---@return boolean
function M.unregister_hook(stage, hook_id)
  local hooks = hook_registry[stage]
  if not hooks then
    error('Unknown hook stage: ' .. tostring(stage))
  end

  for i, entry in ipairs(hooks) do
    if entry.id == hook_id then
      table.remove(hooks, i)
      return true
    end
  end

  return false
end

function M.reset_hooks_for_test()
  for stage, _ in pairs(hook_registry) do
    hook_registry[stage] = {}
  end
  hook_sequence = 0
end

---@param ctx OpencodeCommandActionContext
---@return OpencodeCommandDispatchResult
function M.execute(ctx)
  ---@type OpencodeCommandDispatchContext
  local dispatch_ctx = {
    parsed = ctx.parsed,
    intent = ctx.intent or (ctx.parsed and ctx.parsed.intent) or nil,
    args = ctx.args,
    range = ctx.range,
  }

  local command_name = dispatch_ctx.intent and dispatch_ctx.intent.name or 'unknown'
  log.debug('event=command_execute_start command=%s', command_name)

  ---@param stage 'parse'|'bind'|'execute'
  ---@param err any
  ---@param profile_key 'parse'|'bind'|'execute_missing'|'execute_error'
  ---@return OpencodeCommandDispatchResult
  local function fail(stage, err, profile_key)
    local profile = failure_profiles[profile_key]
    dispatch_ctx.error = M.normalize_error(err, profile.fallback_code, profile.fallback_message)
    dispatch_ctx = run_hook_pipeline('error', dispatch_ctx)
    dispatch_ctx = run_hook_pipeline('finally', dispatch_ctx)
    log.warn(
      'event=command_execute_error command=%s stage=%s code=%s message=%s',
      command_name,
      stage,
      dispatch_ctx.error.code,
      dispatch_ctx.error.message
    )

    local result = {
      ok = false,
      error = dispatch_ctx.error,
    }

    if profile.include_intent then
      result.intent = dispatch_ctx.intent
    end

    return result
  end

  if not (ctx.parsed and ctx.parsed.ok) then
    return fail('parse', ctx.parsed and ctx.parsed.error, 'parse')
  end

  if not dispatch_ctx.intent then
    return fail('bind', { code = 'missing_handler', message = 'Missing command intent' }, 'bind')
  end

  dispatch_ctx.args = dispatch_ctx.args or dispatch_ctx.intent.args or {}
  dispatch_ctx.range = dispatch_ctx.range or dispatch_ctx.intent.range
  dispatch_ctx.intent.args = dispatch_ctx.args
  dispatch_ctx.intent.range = dispatch_ctx.range

  dispatch_ctx = run_hook_pipeline('before', dispatch_ctx)

  local execute_fn = ctx.execute
  if not execute_fn then
    return fail('execute', { code = 'missing_execute', message = 'Command has no execute function' }, 'execute_missing')
  end

  local ok, result_or_err = pcall(execute_fn, dispatch_ctx.args, dispatch_ctx.range)
  if not ok then
    return fail('execute', result_or_err, 'execute_error')
  end

  dispatch_ctx.result = result_or_err
  dispatch_ctx = run_hook_pipeline('after', dispatch_ctx)
  dispatch_ctx = run_hook_pipeline('finally', dispatch_ctx)

  log.debug('event=command_execute_success command=%s', command_name)
  return {
    ok = true,
    result = dispatch_ctx.result,
    intent = dispatch_ctx.intent,
  }
end

return M
