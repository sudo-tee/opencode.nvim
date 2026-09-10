local state = require('opencode.state')
local context = require('opencode.context')
local util = require('opencode.util')
local config = require('opencode.config')
local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local session_runtime = require('opencode.services.session_runtime')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

--- Sends a message to the active session.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  local target_session = vim.deepcopy(state.active_session)
  if not target_session or not target_session.id then
    return false
  end

  if target_session.parentID and config.child_readonly then
    return false
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = vim.deepcopy(opts or {})
  local tab_id = state.active_session_tab
  local session_id = target_session.id
  local api_client = state.api_client
  local target_model = state.current_model
  local target_mode = state.current_mode
  local target_variant = state.current_variant

  opts.context = vim.tbl_deep_extend('force', {}, state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()
  local parts_promise = context.format_message(prompt, opts.context)
  local sent_context = context.snapshot()
  session_tabs.set_context(sent_context)

  opts.model = opts.model or target_model
  if not opts.model then
    local opencode_config = config_file.get_opencode_config():await()
    opts.model = opencode_config and opencode_config.model ~= '' and opencode_config.model or nil
  end
  if opts.agent == nil then
    opts.agent = target_mode or config.default_mode
  end
  opts.variant = opts.variant or target_variant
  local params = {}
  local model_update = {}

  if opts.model then
    local provider, model = opts.model:match('^(.-)/(.+)$')
    params.model = { providerID = provider, modelID = model }
    model_update.model = opts.model

    if opts.variant then
      params.variant = opts.variant
      model_update.variant = opts.variant
    end
  end

  if opts.agent then
    params.agent = opts.agent
    local available_agents = config_file.get_opencode_agents():await()
    if vim.tbl_contains(available_agents, opts.agent) then
      model_update.mode = opts.agent
    end
  end

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

  params.parts = parts_promise:await()
  params.system = opts.system or config.default_system_prompt or nil

  if tab_id and session_tabs.active_id() ~= tab_id then
    local runtime = session_tabs.get(tab_id)
    if runtime then
      runtime.context_data = vim.deepcopy(sent_context)
      runtime.context_data.mentioned_files = {}
      runtime.context_data.selections = {}
    end
  else
    context.unload_attachments()
    session_tabs.set_context(context.snapshot())
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

  api_client
    :create_message(session_id, params)
    :and_then(function(response)
      update_sent_message_count(-1)

      if not response or not response.info or not response.parts then
        log.notify('Invalid response from opencode: ' .. vim.inspect(response), vim.log.levels.ERROR)
        session_runtime.cancel(session_id, tab_id, { count_abort = true }):await()
        return
      end

      M.after_run(prompt, tab_id, sent_context)
    end)
    :catch(function(err)
      log.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      update_sent_message_count(-1)
      session_runtime.cancel(session_id, tab_id, { count_abort = true }):await()
    end)
    :await()
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
      runtime_context.mentioned_files = {}
      runtime_context.selections = {}
      runtime.context_data = runtime_context
    end
    session_tabs.set_last_sent_context(tab_id, sent_context or runtime_context)

    if session_tabs.active_id() == tab_id then
      context.delta_context()
    end
  else
    local context_sent = vim.deepcopy(sent_context or context.get_context())
    if not sent_context then
      context.unload_attachments()
    end
    state.session.set_last_sent_context(context_sent)
    context.delta_context()
  end
  require('opencode.history').write(prompt)
  vim.g.opencode_abort_count = 0
end

return M
