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
local optimistic = require('opencode.state.optimistic')

local M = {}

---@type table<string, {token: string, release: fun()}>
local draft_creations = {}
local next_draft_token = 0
---changedtick covers native completion, which does not fire TextChangedI while the popup is visible.
---@type table<string, number>
local input_ticks = {}

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
---@field selected_model {mode?: string, model?: string, variant?: string}
---@field model_update OpencodeSessionTabModelUpdate

---@class SubmissionSnapshot
---@field mode string|nil
---@field model string|nil
---@field variant string|nil
---@field context_config OpencodeContextConfig|nil
---@field context OpencodeContext
---@field last_sent_context OpencodeContext|nil
---@field session_id string|nil

---@param observation OpencodeObservation
---@param prompt string
---@param opts SendMessageOpts
---@param snapshot? SubmissionSnapshot
---@return PreparedMessage
local function prepare_message(observation, prompt, opts, snapshot)
  -- Replace wholesale: per-field fallbacks would adopt values another tab changed during the wait.
  local selected_model = snapshot
      and {
        mode = snapshot.mode or config.default_mode,
        model = snapshot.model,
        variant = snapshot.variant,
      }
    or {
      mode = state.current_mode or config.default_mode,
      model = state.current_model,
      variant = state.current_variant,
    }
  observation:validate_message_options(opts, config.default_system_prompt)

  local base_config = snapshot and snapshot.context_config or (not snapshot and state.current_context_config or nil)
  opts.context = vim.tbl_deep_extend('force', {}, base_config or {}, opts.context or {})
  if not snapshot then
    state.context.set_current_context_config(opts.context)
    context.load()
  end

  local submission_context = vim.deepcopy(snapshot and snapshot.context or context.get_context())
  local session_id = snapshot and snapshot.session_id
    or (not snapshot and state.active_session and state.active_session.id or nil)
  submission_context.review_comments = vim.tbl_filter(function(comment)
    return comment.session_id == session_id
  end, submission_context.review_comments or {})
  submission_context.automatic_context = {}
  local previous_source = snapshot and snapshot.last_sent_context or (not snapshot and state.last_sent_context or nil)
  local previous_context = previous_source and vim.deepcopy(previous_source)
  ---@type OpencodeMessageSelection
  local selected = {
    mode = snapshot and snapshot.mode or (not snapshot and state.current_mode or nil),
    model = snapshot and snapshot.model or (not snapshot and state.current_model or nil),
    variant = snapshot and snapshot.variant or (not snapshot and state.current_variant or nil),
    default_mode = config.default_mode,
  }
  if observation.needs_message_defaults then
    if opts.model == nil and selected.model == nil then
      local remote_config = config_file.get_opencode_config():await()
      selected.default_model = remote_config and remote_config.model ~= '' and remote_config.model or nil
    end
    if opts.agent or selected.mode or selected.default_mode then
      selected.available_agents = config_file.get_opencode_agents():await()
    end
  end
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
local function await_admission(observation, prepared, pending)
  local response = observation
    :submit(prepared.params, prepared.selected_model, function(id)
      optimistic.bind(pending, id)
    end)
    :await()
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
local function submit_message(observation, prompt, tab_id, session_id, prepared, pending)
  consume_sent_attachments(tab_id, prepared.submission_context)
  session_runtime.update_sent_message_count(tab_id, session_id, 1):await()

  local admitted, response = pcall(await_admission, observation, prepared, pending)
  local ok, result = admitted, response
  if admitted then
    ---@cast response OpencodeSubmission
    ok, result = pcall(complete_submission, response, prompt, tab_id, prepared)
  end

  session_runtime.update_sent_message_count(tab_id, session_id, -1):await()
  optimistic.finish(observation, pending, not ok and (admitted and 'unknown' or 'failed') or nil)
  if not ok then
    local prefix = admitted and 'Prompt result is unknown: ' or 'Error sending message to session: '
    log.notify(prefix .. tostring(result), admitted and vim.log.levels.WARN or vim.log.levels.ERROR)
    return
  end
  return result
end

---Releasing the subscription early restores the session resource to unread, and the submit that follows is rejected.
---@param tab_id string
---@param token string Identifies this attempt; a newer attempt on the same tab invalidates it
---@return OpencodeObservation|nil, SubmissionSnapshot|nil, fun()|nil
local function materialize_draft_session(tab_id, token)
  local runtime = session_tabs.get(tab_id)
  if not runtime or runtime.active_session then
    return nil, nil, nil
  end
  session_tabs.sync(tab_id)
  local snapshot = {
    mode = runtime.current_mode,
    model = runtime.current_model,
    variant = runtime.current_variant,
    context_config = vim.deepcopy(runtime.current_context_config),
    context = vim.deepcopy(runtime.context_data or context.get_context()),
    last_sent_context = runtime.last_sent_context and vim.deepcopy(runtime.last_sent_context),
    session_id = nil,
  }

  local ready = Promise.new()
  local unsubscribe
  local cancelled = false
  local function release()
    cancelled = true
    if unsubscribe then
      unsubscribe()
    end
    ready:resolve(false)
  end
  draft_creations[tab_id] = { token = token, release = release }
  runtime._draft_release = release

  local creation = session_runtime.create_detached_session():catch(function(err)
    log.warn('draft session creation failed: %s', tostring(err))
    return nil
  end)
  local gate = Promise.new()
  creation:and_then(function(value)
    gate:resolve(value)
  end)
  ready:and_then(function()
    gate:resolve(nil)
  end)
  local detached = gate:await()
  local entry = draft_creations[tab_id]
  local owner = session_tabs.get(tab_id)
  if cancelled or not detached or not owner or owner.active_session or not entry or entry.token ~= token then
    release()
    return nil, nil, nil
  end
  local observation = detached.observation
  unsubscribe = observation:watch({ 'session' }, function(observed)
    local state_now = observed:read()
    local sync = state_now.sync and state_now.sync.session
    if sync and (sync.state == 'current' or sync.state == 'error') then
      ready:resolve(sync.state == 'current')
    end
  end)
  local became_ready = ready:await()
  entry = draft_creations[tab_id]
  if not became_ready or not entry or entry.token ~= token then
    release()
    return nil, nil, nil
  end
  owner = session_tabs.get(tab_id)
  if not owner or owner.active_session then
    release()
    return nil, nil, nil
  end

  local session = detached.session
  snapshot.session_id = session.id
  if session_tabs.active_id() == tab_id then
    state.session.set_active(session)
  else
    owner.active_session = session
  end
  return observation, snapshot, release
end

---The active tab's buffer and store are the authority; writing the parked runtime alone is overwritten by the next sync.
---@param tab_id string
---@param prompt string
local function restore_prompt(tab_id, prompt)
  local lines = vim.split(prompt, '\n', { plain = true })
  if session_tabs.active_id() == tab_id then
    state.ui.set_input_content(lines)
    require('opencode.ui.input_window').set_content(lines)
    return
  end
  local runtime = session_tabs.get(tab_id)
  if runtime then
    runtime.input_content = lines
  end
end

--- Sends a message to the active session.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  local tab_id = state.active_session_tab
  local observation = state.session.active_observation()
  local snapshot
  local release_draft
  if not observation then
    if not tab_id then
      return false
    end
    local previous = draft_creations[tab_id]
    if previous then
      previous.release()
    end
    next_draft_token = next_draft_token + 1
    local token = 'draft-' .. next_draft_token
    local windows = state.windows
    local tick = windows and windows.input_buf and vim.api.nvim_buf_get_changedtick(windows.input_buf)
    input_ticks[tab_id] = tick
    observation, snapshot, release_draft = materialize_draft_session(tab_id, token)
    local entry = draft_creations[tab_id]
    if entry and entry.token == token then
      draft_creations[tab_id] = nil
    end
    local runtime = session_tabs.get(tab_id)
    if runtime and runtime._draft_release == release_draft then
      runtime._draft_release = nil
    end
    if not observation then
      local buf = windows and windows.input_buf
      local buf_alive = buf and vim.api.nvim_buf_is_valid(buf)
      local current_tick = buf_alive and vim.api.nvim_buf_get_changedtick(buf)
      if entry and entry.token == token and buf_alive and current_tick == input_ticks[tab_id] then
        restore_prompt(tab_id, prompt)
      end
      return false
    end
  end

  local function abandon(reason)
    if release_draft then
      release_draft()
    end
    if reason then
      log.notify(reason, vim.log.levels.WARN)
    end
    return false
  end

  local observed = observation:read()
  local session_fact = observed.session
  if not session_fact or not observed.sync or not observed.sync.session or observed.sync.session.state ~= 'current' then
    return abandon('Session metadata is not ready')
  end

  if session_fact.parentID and config.child_readonly then
    return abandon()
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return abandon()
  end

  local server = state.opencode_server
  if not server then
    log.notify('Not connected to OpenCode server', vim.log.levels.ERROR)
    return abandon()
  end

  local pending = optimistic.begin(observation, prompt)
  local prepared_ok, prepared = pcall(prepare_message, observation, prompt, vim.deepcopy(opts or {}), snapshot)
  if not prepared_ok then
    optimistic.finish(observation, pending, 'failed')
    if release_draft then
      release_draft()
    end
    error(prepared, 0)
  end
  local result = submit_message(observation, prompt, tab_id, session_fact.id, prepared, pending)
  if release_draft then
    release_draft()
  end
  return result
end)

---@param name string Skill name from the server catalog
---@param prompt? string User instructions; omitted or empty activates the skill directly
--- Resolves after activation or prompt completion; rejects on catalog/activation failure.
M.run_skill = Promise.async(function(name, prompt)
  local connection = assert(state.opencode_server, 'Connection is not ready')
  ---@cast connection OpencodeV1Connection|OpencodeV2Connection
  local observation = state.session.active_observation()
  if not observation then
    error('No active session observation')
  end
  local observed = observation:read()
  local session = observed.session
  if not session or not observed.sync or not observed.sync.session or observed.sync.session.state ~= 'current' then
    error('Session metadata is not ready')
  end
  if session.parentID and config.child_readonly then
    return false
  end
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, context.get_context().mentioned_files or {})
  if not allowed then
    log.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return false
  end
  local directory = state.current_cwd
  ---@cast directory string
  local location = session.location or { directory = directory }
  ---@type table[]
  local skills
  if connection.protocol == 'v2' then
    local v2_connection = connection --[[@as OpencodeV2Connection]]
    skills = v2_connection.operations
      .list_skills(v2_connection, location, util.apply_path_map, util.apply_reverse_path_map)
      :await()
  else
    local v1_connection = connection --[[@as OpencodeV1Connection]]
    skills = v1_connection.operations
      .list_skills(v1_connection, location, util.apply_path_map, util.apply_reverse_path_map)
      :await()
  end
  if state.session.active_observation() ~= observation then
    error('Active session changed while loading skill')
  end
  for _, skill in ipairs(skills) do
    if skill.name == name then
      if connection.protocol == 'v2' then
        if prompt and prompt:match('%S') then
          return M.send_message(prompt, { skills = { { id = skill.id } } }):await()
        end
        ---@cast observation OpencodeV2Observation
        return observation:activate_skill(skill.id):await()
      end
      local message = skill.content
      if prompt and prompt ~= '' then
        message = message .. '\n\n' .. prompt
      end
      return M.send_message(message, {}):await()
    end
  end
  error('Unknown skill: ' .. name)
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
