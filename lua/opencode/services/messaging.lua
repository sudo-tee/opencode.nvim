local state = require('opencode.state')
local context = require('opencode.context')
local util = require('opencode.util')
local config = require('opencode.config')
local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local session_runtime = require('opencode.services.session_runtime')
local agent_model = require('opencode.services.agent_model')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

--- Sends a message to the active session.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  local tab_id = state.active_session_tab
  local observation = state.session.active_observation()
  if not observation then
    return false
  end

  local observed = observation:read()
  local session_fact = observed.session
  if not session_fact or not observed.sync or not observed.sync.session or observed.sync.session.state ~= 'current' then
    log.notify('Session metadata is not ready', vim.log.levels.WARN)
    return false
  end

  if session_fact.parentID and config.child_readonly then
    return false
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = vim.deepcopy(opts or {})
  local explicit_agent = opts.agent ~= nil
  local explicit_model = opts.model ~= nil
  local explicit_variant = opts.variant ~= nil
  local connection = state.opencode_server
  local per_message_settings = connection.protocol == 'v1'
  local session_id = session_fact.id
  local session_model = not per_message_settings and state.current_model or nil
  local session_variant = not per_message_settings and state.current_variant or nil

  if not per_message_settings then
    local system = opts.system
    if system == nil then
      system = config.default_system_prompt
    end
    for _, setting in ipairs({ 'agent', 'model', 'variant' }) do
      if opts[setting] ~= nil then
        error('V2 submit does not support per-message ' .. setting)
      end
    end
    if system ~= nil then
      error('V2 submit does not support a per-message system prompt')
    end
  end

  opts.context = vim.tbl_deep_extend('force', {}, state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()

  local sent_context = vim.deepcopy(context.get_context())
  local model_update = {}

  if not explicit_agent and per_message_settings then
    opts.agent = state.current_mode or config.default_mode
  end
  if not explicit_model and per_message_settings then
    opts.model = state.current_model
    if not opts.model then
      local cfg = config_file.get_opencode_config():await()
      if cfg and cfg.model and cfg.model ~= '' then
        opts.model = cfg.model
      end
    end
  end
  if not explicit_variant and per_message_settings then
    opts.variant = state.current_variant
  end
  local params = context.format_message(prompt, opts.context):await()

  if per_message_settings then
    if opts.model then
      local provider, model = opts.model:match('^(.-)/(.+)$')
      if not provider or not model then
        if explicit_model then
          error('model must use provider/model format')
        end
        opts.model = nil
      else
        params.model = { providerID = provider, modelID = model }
        model_update.model = opts.model
        if opts.variant then
          params.variant = opts.variant
          model_update.variant = opts.variant
        end
      end
    end
    if opts.agent then
      params.agent = opts.agent
      local available_agents = config_file.get_opencode_agents():await()
      if vim.tbl_contains(available_agents, opts.agent) then
        model_update.mode = opts.agent
      end
    end
  end

  params.system = opts.system or config.default_system_prompt or nil

  if tab_id and session_tabs.active_id() ~= tab_id then
    local runtime = session_tabs.get(tab_id)
    if runtime then
      runtime.context_data = vim.deepcopy(sent_context)
      context.consume_attachments(sent_context, runtime.context_data)
    end
  else
    context.consume_attachments(sent_context)
    if tab_id then
      session_tabs.set_context(context.snapshot())
    end
  end

  local function update_sent_message_count(num)
    local runtime = tab_id and session_tabs.get(tab_id)
    if tab_id and not runtime then
      return
    end

    local counts = runtime and runtime.user_message_count or state.user_message_count
    local old_count = counts[session_id] or 0
    local new_count = math.max(0, old_count + num)
    if tab_id then
      session_tabs.update_user_message_count(tab_id, session_id, num)
    else
      local sent_message_count = vim.deepcopy(counts)
      sent_message_count[session_id] = new_count
      state.session.set_user_message_count(sent_message_count)
    end

    if old_count > 0 and new_count == 0 then
      session_runtime.on_session_request_completed(session_id)
    end
  end

  update_sent_message_count(1)
  local admitted = false
  local ok, result = pcall(function()
    if session_model then
      local provider, model = session_model:match('^(.-)/(.+)$')
      if provider and model then
        connection.operations
          .set_session_model(connection, session_id, {
            providerID = provider,
            id = model,
            variant = session_variant,
          })
          :await()
      end
    end
    local response = observation:submit(params):await()
    if type(response) ~= 'table' or (response.kind ~= 'reply' and response.kind ~= 'accepted') then
      error('Invalid prompt result from opencode: ' .. vim.inspect(response))
    end
    admitted = true
    M.after_run(prompt, tab_id, sent_context)

    if tab_id then
      session_tabs.update_model_state(tab_id, model_update)
    else
      if model_update.model then
        state.model.set_model(model_update.model)
      end
      if model_update.mode then
        state.model.set_mode(model_update.mode)
      end
      if model_update.variant then
        state.model.set_variant(model_update.variant)
      end
    end

    return response.completion:await()
  end)
  update_sent_message_count(-1)
  if not ok then
    local prefix = admitted and 'Prompt result is unknown: ' or 'Error sending message to session: '
    log.notify(prefix .. tostring(result), admitted and vim.log.levels.WARN or vim.log.levels.ERROR)
    return
  end
  return result
end)

---@param prompt string
---@param tab_id? string|OpencodeContext
---@param sent_context? OpencodeContext
function M.after_run(prompt, tab_id, sent_context)
  if type(tab_id) == 'table' and sent_context == nil then
    sent_context = tab_id
    tab_id = nil
  end

  if tab_id then
    local runtime = session_tabs.get(tab_id)
    if not runtime then
      require('opencode.history').write(prompt)
      vim.g.opencode_abort_count = 0
      return
    end

    local runtime_context = vim.deepcopy(runtime.context_data or sent_context)
    if runtime_context then
      runtime.context_data = runtime_context
    end
    session_tabs.set_last_sent_context(tab_id, sent_context or runtime_context)

    if session_tabs.active_id() == tab_id then
      context.delta_context()
    end
  else
    local context_sent = vim.deepcopy(sent_context or context.get_context())
    if not sent_context then
      context.consume_attachments(context_sent)
    end
    state.session.set_last_sent_context(context_sent)
    context.delta_context()
  end
  require('opencode.history').write(prompt)
  vim.g.opencode_abort_count = 0
end

return M
