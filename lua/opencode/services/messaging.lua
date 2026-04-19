local state = require('opencode.state')
local context = require('opencode.context')
local util = require('opencode.util')
local config = require('opencode.config')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local agent_model = require('opencode.services.agent_model')
local session_runtime = require('opencode.services.session_runtime')

local M = {}

--- Sends a message to the active session.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  if not state.active_session or not state.active_session.id then
    return false
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  opts.context = vim.tbl_deep_extend('force', state.current_context_config or {}, opts.context or {})
  state.context.set_current_context_config(opts.context)
  context.load()
  opts.model = opts.model or agent_model.initialize_current_model():await()
  opts.agent = opts.agent or state.current_mode or config.default_mode
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
    state.model.set_mode(opts.agent)
  end

  params.parts = context.format_message(prompt, opts.context):await()
  params.system = opts.system or config.default_system_prompt or nil

  local session_id = state.active_session.id

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
        log.notify('Invalid response from opencode: ' .. vim.inspect(response), vim.log.levels.ERROR)
        session_runtime.cancel():await()
        return
      end

      M.after_run(prompt)
    end)
    :catch(function(err)
      log.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      update_sent_message_count(-1)
      session_runtime.cancel():await()
    end)
end)

---@param prompt string
function M.after_run(prompt)
  context.unload_attachments()
  state.session.set_last_sent_context(vim.deepcopy(context.get_context()))
  context.delta_context()
  require('opencode.history').write(prompt)
  vim.g.opencode_abort_count = 0
end

return M
