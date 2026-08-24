local state = require('pi.state')
local context = require('pi.context')
local util = require('pi.util')
local config = require('pi.config')
local config_file = require('pi.config_file')
local Promise = require('pi.promise')
local log = require('pi.log')
local agent_model = require('pi.services.agent_model')
local session_runtime = require('pi.services.session_runtime')

local M = {}

--- Sends a message to the active session.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  if not state.active_session or not state.active_session.id then
    return false
  end

  if state.active_session.parentID and config.child_readonly then
    return false
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  if config.backend == 'pi' then
    opts.context = vim.tbl_deep_extend('force', state.current_context_config or {}, opts.context or {})
    state.context.set_current_context_config(opts.context)
    context.load()
    local parts = context.format_message(prompt, opts.context):await()
    local message = require('pi.prompt_adapter').parts_to_prompt(parts)
    local session_id = state.active_session.id
    local sent_context = vim.deepcopy(context.get_context())
    context.unload_attachments()
    local sent_message_count = vim.deepcopy(state.user_message_count)
    sent_message_count[session_id] = (sent_message_count[session_id] or 0) + 1
    state.session.set_user_message_count(sent_message_count)
    require('pi.rpc_client').get():prompt(message):and_then(function()
      sent_message_count = vim.deepcopy(state.user_message_count)
      sent_message_count[session_id] = math.max(0, (sent_message_count[session_id] or 1) - 1)
      state.session.set_user_message_count(sent_message_count)
      M.after_run(prompt, sent_context)
    end):catch(function(err)
      log.notify('Error sending message to pi: ' .. vim.inspect(err), vim.log.levels.ERROR)
      sent_message_count = vim.deepcopy(state.user_message_count)
      sent_message_count[session_id] = math.max(0, (sent_message_count[session_id] or 1) - 1)
      state.session.set_user_message_count(sent_message_count)
      session_runtime.cancel():await()
    end):await()
    return
  end

  opts.context = vim.tbl_deep_extend('force', state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()
  opts.model = opts.model or agent_model.initialize_current_model():await()
  if opts.agent == nil then
    opts.agent = state.current_mode or config.default_mode
  end
  opts.variant = opts.variant or state.current_variant
  local params = {}

  if opts.model then
    local provider, model = opts.model:match('^(.-)/(.+)$')
    params.model = { providerID = provider, modelID = model }
    state.model.set_model(opts.model)

    if opts.variant then
      params.variant = opts.variant
      state.model.set_variant(opts.variant)
    end
  end

  if opts.agent then
    params.agent = opts.agent
    local available_agents = config_file.get_pi_agents():await()
    if vim.tbl_contains(available_agents, opts.agent) then
      state.model.set_mode(opts.agent)
    end
  end

  params.parts = context.format_message(prompt, opts.context):await()
  params.system = opts.system or config.default_system_prompt or nil

  local session_id = state.active_session.id
  local sent_context = vim.deepcopy(context.get_context())
  context.unload_attachments()

  local function update_sent_message_count(num)
    local sent_message_count = vim.deepcopy(state.user_message_count)
    local new_value = (sent_message_count[session_id] or 0) + num
    sent_message_count[session_id] = new_value >= 0 and new_value or 0
    state.session.set_user_message_count(sent_message_count)
  end

  update_sent_message_count(1)

  state.api_client
    :create_message(session_id, params)
    :and_then(function(response)
      update_sent_message_count(-1)

      if not response or not response.info or not response.parts then
        log.notify('Invalid response from pi: ' .. vim.inspect(response), vim.log.levels.ERROR)
        session_runtime.cancel():await()
        return
      end

      M.after_run(prompt, sent_context)
    end)
    :catch(function(err)
      log.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      update_sent_message_count(-1)
      session_runtime.cancel():await()
    end)
    :await()
end)

---@param prompt string
---@param sent_context? PiContext
function M.after_run(prompt, sent_context)
  local context_sent = vim.deepcopy(sent_context or context.get_context())
  if not sent_context then
    context.unload_attachments()
  end
  state.session.set_last_sent_context(context_sent)
  context.delta_context()
  require('pi.history').write(prompt)
  vim.g.pi_abort_count = 0
end

return M
