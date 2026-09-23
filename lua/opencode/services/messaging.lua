local state = require('opencode.state')
local context = require('opencode.context')
local util = require('opencode.util')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local session_runtime = require('opencode.services.session_runtime')
local agent_model = require('opencode.services.agent_model')
local session_tabs = require('opencode.state.session_tabs')

local M = {}

---@param tab_id? string
---@param submission_context OpencodeContext
local function consume_sent_attachments(tab_id, submission_context)
  if tab_id and session_tabs.active_id() ~= tab_id then
    local runtime = session_tabs.get(tab_id)
    if runtime then
      runtime.context_data = vim.deepcopy(submission_context)
      context.consume_attachments(submission_context, runtime.context_data)
    end
    return
  end

  context.consume_attachments(submission_context)
  if tab_id then
    session_tabs.set_context(context.snapshot())
  end
end

---@class PreparedMessage
---@field params table
---@field submission_context OpencodeContext
---@field selected_model {model?: string, variant?: string}
---@field model_update OpencodeSessionTabModelUpdate

---@param observation OpencodeObservation
---@param prompt string
---@param opts SendMessageOpts
---@return PreparedMessage
local function prepare_message(observation, prompt, opts)
  local selected_model = { model = state.current_model, variant = state.current_variant }
  observation:validate_message_options(opts, config.default_system_prompt)

  opts.context = vim.tbl_deep_extend('force', {}, state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()

  local submission_context = vim.deepcopy(context.get_context())
  submission_context.automatic_context = {}
  local previous_context = state.last_sent_context and vim.deepcopy(state.last_sent_context)
  local selected = {
    mode = state.current_mode,
    model = state.current_model,
    variant = state.current_variant,
    default_mode = config.default_mode,
  }
  local overrides, model_update = observation:prepare_message(opts, selected)
  local params = context
    .format_message(prompt, opts.context, {
      previous_context = previous_context,
      submission_context = submission_context,
    })
    :await()
  params = vim.tbl_extend('force', params, overrides)
  params.system = opts.system or config.default_system_prompt or nil

  return {
    params = params,
    submission_context = submission_context,
    selected_model = selected_model,
    model_update = model_update,
  }
end

---@param prepared PreparedMessage
---@return OpencodeSubmission
local function await_admission(observation, prepared)
  local response = observation:submit(prepared.params, prepared.selected_model):await()
  if type(response) ~= 'table' or (response.kind ~= 'reply' and response.kind ~= 'accepted') then
    error('Invalid prompt result from opencode: ' .. vim.inspect(response))
  end
  return response
end

---@param response OpencodeSubmission
---@param prompt string
---@param tab_id? string
---@param prepared PreparedMessage
local function complete_submission(response, prompt, tab_id, prepared)
  M.after_run(prompt, tab_id, prepared.submission_context)
  agent_model.apply_message_update(tab_id, prepared.model_update)
  return response.completion:await()
end

---@param prompt string
---@param tab_id? string
---@param session_id string
---@param prepared PreparedMessage
local function submit_message(observation, prompt, tab_id, session_id, prepared)
  consume_sent_attachments(tab_id, prepared.submission_context)
  session_runtime.update_sent_message_count(tab_id, session_id, 1)

  local admitted, response = pcall(await_admission, observation, prepared)
  local ok, result = admitted, response
  if admitted then
    ---@cast response OpencodeSubmission
    ok, result = pcall(complete_submission, response, prompt, tab_id, prepared)
  end

  session_runtime.update_sent_message_count(tab_id, session_id, -1)
  if not ok then
    local prefix = admitted and 'Prompt result is unknown: ' or 'Error sending message to session: '
    log.notify(prefix .. tostring(result), admitted and vim.log.levels.WARN or vim.log.levels.ERROR)
    return
  end
  return result
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

  local server = state.opencode_server
  if not server then
    log.notify('Not connected to OpenCode server', vim.log.levels.ERROR)
    return false
  end

  local prepared = prepare_message(observation, prompt, vim.deepcopy(opts or {}))
  return submit_message(observation, prompt, tab_id, session_fact.id, prepared)
end)

---@param prompt string
---@param tab_id? string|OpencodeContext
---@param submission_context? OpencodeContext
function M.after_run(prompt, tab_id, submission_context)
  if type(tab_id) == 'table' and submission_context == nil then
    submission_context = tab_id
    tab_id = nil
  end
  ---@cast tab_id string?
  ---@cast submission_context OpencodeContext?

  if tab_id then
    local runtime = session_tabs.get(tab_id)
    if runtime then
      local source_context = runtime.context_data or submission_context
      local runtime_context = source_context and vim.deepcopy(source_context)
      if runtime_context then
        runtime.context_data = runtime_context
      end
      session_tabs.set_last_sent_context(tab_id, submission_context or runtime_context)
    end
  else
    local context_sent = vim.deepcopy(submission_context or context.get_context())
    if not submission_context then
      context.consume_attachments(context_sent)
    end
    state.session.set_last_sent_context(context_sent)
  end
  require('opencode.history').write(prompt)
  vim.g.opencode_abort_count = 0
end

return M
