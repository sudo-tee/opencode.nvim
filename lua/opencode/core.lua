-- This file was written by an automated tool.
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local server_job = require('opencode.server_job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')
local config = require('opencode.config')

local M = {}
M._abort_count = 0

---@param parent_id string?
function M.select_session(parent_id)
  local all_sessions = session.get_all_workspace_sessions() or {}
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
end

function M.switch_session(session_id)
  local selected_session = session.get_by_id(session_id)

  state.current_model = nil
  state.current_mode = nil
  M.ensure_current_mode()

  state.active_session = selected_session
  if state.windows then
    state.restore_points = {}
    ui.focus_input()
  else
    M.open()
  end
end

---@param opts? OpenOpts
function M.open(opts)
  opts = opts or { focus = 'input', new_session = false }

  if not state.opencode_server or not state.opencode_server:is_running() then
    state.opencode_server = server_job.ensure_server() --[[@as OpencodeServer]]
  end

  M.ensure_current_mode()

  local are_windows_closed = state.windows == nil

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
  end

  if are_windows_closed then
    -- Check if whether prompting will be allowed
    local mentioned_files = context.context.mentioned_files or {}
    local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)
    if not allowed then
      vim.notify(err_msg or 'Prompts will be denied by prompt_guard', vim.log.levels.WARN)
    end

    state.windows = ui.create_windows()
  end

  if opts.new_session then
    state.active_session = nil
    state.last_sent_context = nil

    state.current_model = nil
    state.current_mode = nil
    M.ensure_current_mode()

    state.active_session = M.create_new_session()
  else
    if not state.active_session then
      state.active_session = session.get_last_workspace_session()
      if not state.active_session then
        state.active_session = M.create_new_session()
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

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed, start_insert = opts.start_insert == true })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end
  state.is_opencode_focused = true
end

--- Sends a message to the active session, creating one if necessary.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
function M.send_message(prompt, opts)
  if not state.active_session or not state.active_session.id then
    return false
  end

  local mentioned_files = context.context.mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)

  if not allowed then
    vim.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
    return
  end

  opts = opts or {}

  opts.context = vim.tbl_deep_extend('force', state.current_context_config or {}, opts.context or {})
  state.current_context_config = opts.context
  context.load()
  opts.model = opts.model or M.initialize_current_model()
  opts.agent = opts.agent or state.current_mode or config.default_mode

  local params = {}

  if opts.model then
    local provider, model = opts.model:match('^(.-)/(.+)$')
    params.model = { providerID = provider, modelID = model }
    state.current_model = opts.model
  end

  if opts.agent then
    params.agent = opts.agent
    state.current_mode = opts.agent
  end

  params.parts = context.format_message(prompt, opts.context)
  M.before_run(opts)

  state.user_message_count = state.user_message_count + 1
  state.api_client
    :create_message(state.active_session.id, params)
    :and_then(function(response)
      if not response or not response.info or not response.parts then
        -- fall back to full render. incremental render is handled
        -- event manager
        ui.render_output()
      end
      state.user_message_count = state.user_message_count - 1

      M.after_run(prompt)
    end)
    :catch(function(err)
      vim.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      M.cancel()
    end)
end

---@param title? string
---@return Session?
function M.create_new_session(title)
  local session_response = state.api_client
    :create_session(title and { title = title } or false)
    :catch(function(err)
      vim.notify('Error creating new session: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
    :wait()

  if session_response and session_response.id then
    local new_session = session.get_by_id(session_response.id)
    return new_session
  end
end

---@param prompt string
function M.after_run(prompt)
  context.unload_attachments()
  state.last_sent_context = vim.deepcopy(context.context)
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
  require('opencode.provider').select(function(selection)
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
      vim.notify('Changed provider to ' .. selection.display, vim.log.levels.INFO)
    end
  end)
end

function M.cancel()
  if state.windows and state.active_session then
    if state.is_running() then
      M._abort_count = M._abort_count + 1

      -- if there's a current permission, reject it
      if state.current_permission then
        require('opencode.api').permission_deny()
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
          state.opencode_server:shutdown():wait()
        end

        -- start a new one
        state.opencode_server = nil

        -- NOTE: start a new server here to make sure we're subscribed
        -- to server events before a user sends a message
        state.opencode_server = server_job.ensure_server() --[[@as OpencodeServer]]
      end
    end
    require('opencode.ui.footer').clear()
    input_window.set_content('')
    require('opencode.history').index = nil
    ui.focus_input()
  end
end

function M.opencode_ok()
  if vim.fn.executable('opencode') == 0 then
    vim.notify(
      'opencode command not found - please install and configure opencode before using this plugin',
      vim.log.levels.ERROR
    )
    return false
  end

  if not state.opencode_cli_version or state.opencode_cli_version == '' then
    local result = vim.system({ 'opencode', '--version' }):wait()
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
end

local function on_opencode_server()
  state.current_permission = nil
end

--- Switches the current mode to the specified agent.
--- @param mode string|nil The agent/mode to switch to
--- @return boolean success Returns true if the mode was switched successfully, false otherwise
function M.switch_to_mode(mode)
  if not mode or mode == '' then
    vim.notify('Mode cannot be empty', vim.log.levels.ERROR)
    return false
  end

  local config_file = require('opencode.config_file')
  local available_agents = config_file.get_opencode_agents()

  if not vim.tbl_contains(available_agents, mode) then
    vim.notify(
      string.format('Invalid mode "%s". Available modes: %s', mode, table.concat(available_agents, ', ')),
      vim.log.levels.ERROR
    )
    return false
  end

  state.current_mode = mode
  local opencode_config = config_file.get_opencode_config()
  local agent_config = opencode_config and opencode_config.agent or {}
  local mode_config = agent_config[mode] or {}
  if mode_config.model and mode_config.model ~= '' then
    state.current_model = mode_config.model
  end
  return true
end

--- Ensure the current_mode is set using the config.default_mode or falling back to the first available agent.
--- @return boolean success Returns true if current_mode is set
function M.ensure_current_mode()
  if state.current_mode == nil then
    local config_file = require('opencode.config_file')
    local available_agents = config_file.get_opencode_agents()

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
end

---Initialize current model if it's not already set.
---@return string|nil The current model (or the default model, if configured)
function M.initialize_current_model()
  if state.current_model then
    return state.current_model
  end

  local config_file = require('opencode.config_file').get_opencode_config()

  if config_file and config_file.model and config_file.model ~= '' then
    state.current_model = config_file.model
  end

  return state.current_model
end

local function on_user_message_count_change(_, new, old)
  local done_thinking = new == 0 and old > 0
  if config.hooks and config.hooks.on_done_thinking and done_thinking then
    pcall(config.hooks.on_done_thinking)
  end
end

local function on_current_permission_change(_, new, old)
  local permission_requested = old == nil and new ~= nil
  if config.hooks and config.hooks.on_permission_requested and permission_requested then
    pcall(config.hooks.on_permission_requested)
  end
end

function M.setup()
  state.subscribe('opencode_server', on_opencode_server)
  state.subscribe('user_message_count', on_user_message_count_change)
  state.subscribe('current_permission', on_current_permission_change)

  vim.schedule(function()
    M.opencode_ok()
  end)
  local OpencodeApiClient = require('opencode.api_client')
  state.api_client = OpencodeApiClient.create()
end

return M
