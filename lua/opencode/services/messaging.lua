local state = require('opencode.state')
local context = require('opencode.context')
local util = require('opencode.util')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local session_runtime = require('opencode.services.session_runtime')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

---@param tab_id? string
---@param sent_context OpencodeContext
local function consume_sent_attachments(tab_id, sent_context)
  if tab_id and session_tabs.active_id() ~= tab_id then
    local runtime = session_tabs.get(tab_id)
    if runtime then
      runtime.context_data = vim.deepcopy(sent_context)
      context.consume_attachments(sent_context, runtime.context_data)
    end
    return
  end

  context.consume_attachments(sent_context)
  if tab_id then
    session_tabs.set_context(context.snapshot())
  end
end

---@param tab_id? string
---@param session_id string
---@param num integer
local function update_sent_message_count(tab_id, session_id, num)
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

---@param tab_id? string
---@param model_update OpencodeSessionTabModelUpdate
local function apply_model_update(tab_id, model_update)
  if tab_id then
    session_tabs.update_model_state(tab_id, model_update)
    return
  end

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
  local connection = state.opencode_server
  if not connection then
    log.notify('Not connected to OpenCode server', vim.log.levels.ERROR)
    return false
  end

  local session_id = session_fact.id
  local selected_model = {
    model = state.current_model,
    variant = state.current_variant,
  }
  observation:validate_message_options(opts, config.default_system_prompt)

  opts.context = vim.tbl_deep_extend('force', {}, state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()

  local sent_context = vim.deepcopy(context.get_context())
  local overrides, model_update = observation:prepare_message(opts, {
    mode = state.current_mode,
    model = state.current_model,
    variant = state.current_variant,
    default_mode = config.default_mode,
  })
  local params = context.format_message(prompt, opts.context):await()
  params = vim.tbl_extend('force', params, overrides)

  params.system = opts.system or config.default_system_prompt or nil

  consume_sent_attachments(tab_id, sent_context)

  update_sent_message_count(tab_id, session_id, 1)
  local admitted = false
  local ok, result = pcall(function()
    local response = observation:submit(params, selected_model):await()
    if type(response) ~= 'table' or (response.kind ~= 'reply' and response.kind ~= 'accepted') then
      error('Invalid prompt result from opencode: ' .. vim.inspect(response))
    end
    admitted = true
    M.after_run(prompt, tab_id, sent_context)

    apply_model_update(tab_id, model_update)

    return response.completion:await()
  end)
  update_sent_message_count(tab_id, session_id, -1)
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
    if runtime then
      local runtime_context = vim.deepcopy(runtime.context_data or sent_context)
      if runtime_context then
        runtime.context_data = runtime_context
      end
      session_tabs.set_last_sent_context(tab_id, sent_context or runtime_context)

      if session_tabs.active_id() == tab_id then
        context.delta_context()
      end
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
