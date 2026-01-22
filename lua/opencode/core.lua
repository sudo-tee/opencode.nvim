-- This file was written by an automated tool.
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local server_job = require('opencode.server_job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')
local config = require('opencode.config')
local image_handler = require('opencode.image_handler')
local Promise = require('opencode.promise')
local permission_window = require('opencode.ui.permission_window')

local M = {}
M._abort_count = 0

---@param parent_id string?
M.select_session = Promise.async(function(parent_id)
  local all_sessions = session.get_all_workspace_sessions():await() or {}
  ---@cast all_sessions Session[]

  local filtered_sessions = vim.tbl_filter(function(s)
    return s.title ~= '' and s ~= nil and s.parentID == parent_id
  end, all_sessions)

  ui.select_session(filtered_sessions, function(selected_session)
    if not selected_session then
      if state.windows then
        ui.focus_input()
      end
      return
    end
    M.switch_session(selected_session.id)
  end)
end)

M.switch_session = Promise.async(function(session_id)
  local selected_session = session.get_by_id(session_id):await()

  state.current_model = nil
  state.current_mode = nil
  M.ensure_current_mode():await()

  state.active_session = selected_session
  if state.windows then
    state.restore_points = {}
    ui.focus_input()
  else
    M.open()
  end
end)

---@param opts? OpenOpts
M.open_if_closed = Promise.async(function(opts)
  if not state.windows then
    M.open(opts):await()
  end
end)

---@param opts? OpenOpts
M.open = Promise.async(function(opts)
  opts = opts or { focus = 'input', new_session = false }

  state.is_opening = true

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
  end

  local are_windows_closed = state.windows == nil
  if are_windows_closed then
    -- Check if whether prompting will be allowed
    local mentioned_files = context.get_context().mentioned_files or {}
    local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)
    if not allowed then
      vim.notify(err_msg or 'Prompts will be denied by prompt_guard', vim.log.levels.WARN)
    end

    state.windows = ui.create_windows()
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed, start_insert = opts.start_insert == true })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end

  local server = server_job.ensure_server():await()
  state.opencode_server = server

  local ok, err = pcall(function()
    state.opencode_server = server

    if opts.new_session then
      state.active_session = nil
      state.last_sent_context = nil
      context.unload_attachments()

      state.current_model = nil
      state.current_mode = nil
      M.ensure_current_mode():await()

      state.active_session = M.create_new_session():await()
    else
      M.ensure_current_mode():await()
      if not state.active_session then
        state.active_session = session.get_last_workspace_session():await()
        if not state.active_session then
          state.active_session = M.create_new_session():await()
        end
      else
        if not state.display_route and are_windows_closed then
          -- We're not displaying /help or something like that but we have an active session
          -- and the windows were closed so we need to do a full refresh. This mostly happens
          -- when opening the window after having closed it since we're not currently clearing
          -- the session on api.close()
          ui.render_output()
        end
      end
    end

    state.is_opencode_focused = true
  end)

  state.is_opening = false

  if not ok then
    vim.notify('Error opening panel: ' .. tostring(err), vim.log.levels.ERROR)
    return Promise.new():reject(err)
  end
  return Promise.new():resolve('ok')
end)

--- Sends a message to the active session, creating one if necessary.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
M.send_message = Promise.async(function(prompt, opts)
  if not state.active_session or not state.active_session.id then
    return false
  end

  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    vim.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  opts.context = vim.tbl_deep_extend('force', state.current_context_config or {}, opts.context or {})
  state.current_context_config = opts.context
  context.load()
  opts.model = opts.model or M.initialize_current_model():await()
  opts.agent = opts.agent or state.current_mode or config.default_mode
  opts.variant = opts.variant or state.current_variant
  local params = {}

  if opts.model then
    local provider, model = opts.model:match('^(.-)/(.+)$')
    params.model = { providerID = provider, modelID = model }
    state.current_model = opts.model

    if opts.variant then
      params.variant = opts.variant
      state.current_variant = opts.variant
    end
  end

  if opts.agent then
    params.agent = opts.agent
    state.current_mode = opts.agent
  end

  params.parts = context.format_message(prompt, opts.context):await()
  M.before_run(opts)

  local session_id = state.active_session.id

  ---Helper to update state.user_message_count. Have to deepcopy since it's a table to make
  ---sure notification events fire. Prevents negative values (in case of an untracked code path)
  local function update_sent_message_count(num)
    local sent_message_count = vim.deepcopy(state.user_message_count)
    local new_value = (sent_message_count[session_id] or 0) + num
    sent_message_count[session_id] = new_value >= 0 and new_value or 0
    state.user_message_count = sent_message_count
  end

  update_sent_message_count(1)

  state.api_client
    :create_message(session_id, params)
    :and_then(function(response)
      update_sent_message_count(-1)

      if not response or not response.info or not response.parts then
        vim.notify('Invalid response from opencode: ' .. vim.inspect(response), vim.log.levels.ERROR)
        M.cancel()
        return
      end

      M.after_run(prompt)
    end)
    :catch(function(err)
      vim.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      update_sent_message_count(-1)
      M.cancel()
    end)
end)

---@param title? string
---@return Session?
M.create_new_session = Promise.async(function(title)
  local session_response = state.api_client
    :create_session(title and { title = title } or false)
    :catch(function(err)
      vim.notify('Error creating new session: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
    :await()

  if session_response and session_response.id then
    local new_session = session.get_by_id(session_response.id):await()
    return new_session
  end
end)

---@param prompt string
function M.after_run(prompt)
  context.unload_attachments()
  state.last_sent_context = vim.deepcopy(context.get_context())
  context.delta_context()
  require('opencode.history').write(prompt)
  M._abort_count = 0
end

---@param opts? SendMessageOpts
function M.before_run(opts)
  local is_new_session = opts and opts.new_session or not state.active_session
  opts = opts or {}

  M.open({
    new_session = is_new_session,
  })
end

function M.configure_provider()
  require('opencode.model_picker').select(function(selection)
    if not selection then
      if state.windows then
        ui.focus_input()
      end
      return
    end
    local model_str = string.format('%s/%s', selection.provider, selection.model)
    state.current_model = model_str

    if state.windows then
      ui.focus_input()
    else
      vim.notify('Changed provider to ' .. model_str, vim.log.levels.INFO)
    end
  end)
end

function M.configure_variant()
  require('opencode.variant_picker').select(function(selection)
    if not selection then
      if state.windows then
        ui.focus_input()
      end
      return
    end

    state.current_variant = selection.name

    if state.windows then
      ui.focus_input()
    else
      vim.notify('Changed variant to ' .. selection.name, vim.log.levels.INFO)
    end
  end)
end

M.cycle_variant = Promise.async(function()
  if not state.current_model then
    vim.notify('No model selected', vim.log.levels.WARN)
    return
  end

  local provider, model = state.current_model:match('^(.-)/(.+)$')
  if not provider or not model then
    return
  end

  local config_file = require('opencode.config_file')
  local model_info = config_file.get_model_info(provider, model)

  if not model_info or not model_info.variants then
    vim.notify('Current model does not support variants', vim.log.levels.WARN)
    return
  end

  local variants = {}
  for variant_name, _ in pairs(model_info.variants) do
    table.insert(variants, variant_name)
  end

  util.sort_by_priority(variants, function(item)
    return item
  end, { low = 1, medium = 2, high = 3 })

  if #variants == 0 then
    return
  end

  local total_count = #variants + 1

  local current_index
  if state.current_variant == nil then
    current_index = total_count
  else
    current_index = util.index_of(variants, state.current_variant) or 0
  end

  local next_index = (current_index % total_count) + 1

  local next_variant
  if next_index > #variants then
    next_variant = nil
  else
    next_variant = variants[next_index]
  end

  state.current_variant = next_variant

  local model_state = require('opencode.model_state')
  model_state.set_variant(provider, model, next_variant)
end)

M.cancel = Promise.async(function()
  if state.windows and state.active_session then
    if state.is_running() then
      M._abort_count = M._abort_count + 1

      local permissions = state.pending_permissions or {}
      if #permissions and state.api_client then
        for _, permission in ipairs(permissions) do
          require('opencode.api').permission_deny(permission)
        end
      end

      local ok, result = pcall(function()
        return state.api_client:abort_session(state.active_session.id):wait()
      end)

      if not ok then
        vim.notify('Abort error: ' .. vim.inspect(result))
      end

      if M._abort_count >= 3 then
        vim.notify('Re-starting Opencode server')
        M._abort_count = 0
        -- close existing server
        if state.opencode_server then
          state.opencode_server:shutdown():await()
        end

        -- start a new one
        state.opencode_server = nil

        -- NOTE: start a new server here to make sure we're subscribed
        -- to server events before a user sends a message
        state.opencode_server = server_job.ensure_server():await() --[[@as OpencodeServer]]
      end
    end
    require('opencode.ui.footer').clear()
    input_window.set_content('')
    require('opencode.history').index = nil
    ui.focus_input()
  end
end)

M.opencode_ok = Promise.async(function()
  if vim.fn.executable(config.opencode_executable) == 0 then
    vim.notify(
      'opencode command not found - please install and configure opencode before using this plugin',
      vim.log.levels.ERROR
    )
    return false
  end

  if not state.opencode_cli_version or state.opencode_cli_version == '' then
    local result = Promise.system({ config.opencode_executable, '--version' }):await()
    local out = (result and result.stdout or ''):gsub('%s+$', '')
    state.opencode_cli_version = out:match('(%d+%%.%d+%%.%d+)') or out
  end

  local required = state.required_version
  local current_version = state.opencode_cli_version

  if not current_version or current_version == '' then
    vim.notify(string.format('Unable to detect opencode CLI version. Requires >= %s', required), vim.log.levels.ERROR)
    return false
  end

  if not util.is_version_greater_or_equal(current_version, required) then
    vim.notify(
      string.format('Unsupported opencode CLI version: %s. Requires >= %s', current_version, required),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end)

local function on_opencode_server()
  permission_window.clear_all()
end

--- Switches the current mode to the specified agent.
--- @param mode string|nil The agent/mode to switch to
--- @return boolean success Returns true if the mode was switched successfully, false otherwise
M.switch_to_mode = Promise.async(function(mode)
  if not mode or mode == '' then
    vim.notify('Mode cannot be empty', vim.log.levels.ERROR)
    return false
  end

  local config_file = require('opencode.config_file')
  local available_agents = config_file.get_opencode_agents():await()

  if not vim.tbl_contains(available_agents, mode) then
    vim.notify(
      string.format('Invalid mode "%s". Available modes: %s', mode, table.concat(available_agents, ', ')),
      vim.log.levels.ERROR
    )
    return false
  end

  state.current_mode = mode
  local opencode_config = config_file.get_opencode_config():await() --[[@as OpencodeConfigFile]]

  local agent_config = opencode_config and opencode_config.agent or {}
  local mode_config = agent_config[mode] or {}
  if mode_config.model and mode_config.model ~= '' then
    state.current_model = mode_config.model
  end
  return true
end)

--- Ensure the current_mode is set using the config.default_mode or falling back to the first available agent.
--- @return boolean success Returns true if current_mode is set
M.ensure_current_mode = Promise.async(function()
  if state.current_mode == nil then
    local config_file = require('opencode.config_file')
    local available_agents = config_file.get_opencode_agents():await()

    if not available_agents or #available_agents == 0 then
      vim.notify('No available agents found', vim.log.levels.ERROR)
      return false
    end

    local default_mode = config.default_mode

    -- Try to use the configured default mode if it's available
    if default_mode and vim.tbl_contains(available_agents, default_mode) then
      state.current_mode = default_mode
    else
      -- Fallback to first available agent
      state.current_mode = available_agents[1]
    end
  end
  return true
end)

---Initialize current model if it's not already set.
---@return string|nil The current model (or the default model, if configured)
M.initialize_current_model = Promise.async(function()
  if state.current_model then
    return state.current_model
  end

  local cfg = require('opencode.config_file').get_opencode_config():await()

  if cfg and cfg.model and cfg.model ~= '' then
    state.current_model = cfg.model
  end

  return state.current_model
end)

M._on_user_message_count_change = Promise.async(function(_, new, old)
  if config.hooks and config.hooks.on_done_thinking then
    local all_sessions = session.get_all_workspace_sessions():await()
    local done_sessions = vim.tbl_filter(function(s)
      local msg_count = new[s.id] or 0
      local old_msg_count = (old and old[s.id]) or 0
      return msg_count == 0 and old_msg_count > 0
    end, all_sessions or {})

    for _, done_session in ipairs(done_sessions) do
      pcall(config.hooks.on_done_thinking, done_session)
    end
  end
end)

M._on_current_permission_change = Promise.async(function(_, new, old)
  local permission_requested = #old < #new
  if config.hooks and config.hooks.on_permission_requested and permission_requested then
    local local_session = (state.active_session and state.active_session.id)
        and session.get_by_id(state.active_session.id):await()
      or {}
    pcall(config.hooks.on_permission_requested, local_session)
  end
end)

--- Handle clipboard image data by saving it to a file and adding it to context
--- @return boolean success True if image was successfully handled
function M.paste_image_from_clipboard()
  return image_handler.paste_image_from_clipboard()
end

function M.setup()
  state.subscribe('opencode_server', on_opencode_server)
  state.subscribe('user_message_count', M._on_user_message_count_change)
  state.subscribe('pending_permissions', M._on_current_permission_change)
  state.subscribe('current_model', function(key, new_val, old_val)
    if new_val ~= old_val then
      state.current_variant = nil

      -- Load saved variant for the new model
      if new_val then
        local provider, model = new_val:match('^(.-)/(.+)$')
        if provider and model then
          local model_state = require('opencode.model_state')
          local saved_variant = model_state.get_variant(provider, model)
          if saved_variant then
            state.current_variant = saved_variant
          end
        end
      end
    end
  end)

  vim.schedule(function()
    M.opencode_ok()
  end)
  local OpencodeApiClient = require('opencode.api_client')
  state.api_client = OpencodeApiClient.create()
end

return M
