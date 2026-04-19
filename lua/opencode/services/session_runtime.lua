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
local log = require('opencode.log')
local agent_model = require('opencode.services.agent_model')

local M = {}

---@param parent_id string?
M.select_session = Promise.async(function(parent_id)
  local all_sessions = session.get_all_workspace_sessions():await() or {}
  ---@cast all_sessions Session[]

  local filtered_sessions = vim.tbl_filter(function(s)
    return s.title ~= '' and s ~= nil and s.parentID == parent_id
  end, all_sessions)

  if #filtered_sessions == 0 then
    vim.notify(parent_id and 'No child sessions found' or 'No sessions found', vim.log.levels.INFO)
    if state.ui.is_visible() then
      ui.focus_input()
    end
    return
  end

  ui.select_session(filtered_sessions, function(selected_session)
    if not selected_session then
      if state.ui.is_visible() then
        ui.focus_input()
      end
      return
    end
    M.switch_session(selected_session.id)
  end)
end)

M.switch_session = Promise.async(function(session_id)
  local selected_session = session.get_by_id(session_id):await()

  state.model.clear()
  agent_model.ensure_current_mode():await()

  state.session.set_active(selected_session)
  if state.ui.is_visible() then
    ui.focus_input()
  else
    M.open()
  end
end)

---@param opts? OpenOpts
M.open_if_closed = Promise.async(function(opts)
  if not state.ui.is_visible() then
    M.open(opts):await()
  end
end)

M.is_prompting_allowed = function()
  local mentioned_files = context.get_context().mentioned_files or {}
  local allowed, err_msg = util.check_prompt_allowed(config.prompt_guard, mentioned_files)
  if not allowed then
    vim.notify(err_msg or 'Prompt denied by prompt_guard', vim.log.levels.ERROR)
  end
  return allowed
end

M.check_cwd = function()
  if state.current_cwd ~= vim.fn.getcwd() then
    log.debug(
      'CWD changed since last check, resetting session and context',
      { current_cwd = state.current_cwd, new_cwd = vim.fn.getcwd() }
    )
    state.context.set_current_cwd(vim.fn.getcwd())
    state.session.clear_active()
    context.unload_attachments()
  end
end

---@param opts? OpenOpts
M.open = Promise.async(function(opts)
  opts = opts or { focus = 'input', new_session = false }

  state.ui.set_opening(true)

  if not require('opencode.ui.ui').is_opencode_focused() then
    require('opencode.context').load()
  end

  local open_windows_action = opts.open_action or state.ui.resolve_open_windows_action()
  local are_windows_closed = open_windows_action ~= 'reuse_visible'
  local restoring_hidden = open_windows_action == 'restore_hidden'

  if are_windows_closed then
    if not ui.is_opencode_focused() then
      state.ui.set_code_context(vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf())
    end

    M.is_prompting_allowed()

    if restoring_hidden then
      local restored = ui.restore_hidden_windows()
      if not restored then
        state.ui.clear_hidden_window_state()
        restoring_hidden = false
        state.ui.set_windows(ui.create_windows())
      end
    else
      state.ui.set_windows(ui.create_windows())
    end
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed, start_insert = opts.start_insert == true })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end

  local server = server_job.ensure_server():await()

  if not server then
    state.ui.set_opening(false)
    return Promise.new():reject('Server failed to start')
  end

  M.check_cwd()

  local ok, err = pcall(function()
    if opts.new_session then
      state.session.clear_active()
      context.unload_attachments()
      agent_model.ensure_current_mode():await()
      state.session.set_active(M.create_new_session():await())
      log.debug('Created new session on open', { session = state.active_session.id })
    else
      agent_model.ensure_current_mode():await()
      if not state.active_session then
        state.session.set_active(session.get_last_workspace_session():await())
        if not state.active_session then
          state.session.set_active(M.create_new_session():await())
        end
      elseif not state.display_route and are_windows_closed and not restoring_hidden then
        ui.render_output()
      end
    end

    state.ui.set_panel_focused(true)
  end)

  state.ui.set_opening(false)

  if not ok then
    vim.notify('Error opening panel: ' .. tostring(err), vim.log.levels.ERROR)
    return Promise.new():reject(err)
  end
  return Promise.new():resolve('ok')
end)

---@param title_or_opts? string|boolean|table
---@return Session?
M.create_new_session = Promise.async(function(title_or_opts)
  local session_request = false

  if type(title_or_opts) == 'string' then
    session_request = { title = title_or_opts }
  elseif type(title_or_opts) == 'table' and next(title_or_opts) ~= nil then
    session_request = title_or_opts
  end

  local session_response = state.api_client
    :create_session(session_request)
    :catch(function(err)
      vim.notify('Error creating new session: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
    :await()

  if session_response and session_response.id then
    local new_session = session.get_by_id(session_response.id):await()
    return new_session
  end
end)

---@param opts? SendMessageOpts
function M.before_run(opts)
  local is_new_session = opts and opts.new_session or not state.active_session
  M.open({
    new_session = is_new_session,
  })
end

---@param opts? SendMessageOpts
M.cancel = Promise.async(function()
  if state.active_session and state.jobs.is_running() then
    vim.g.opencode_abort_count = (vim.g.opencode_abort_count or 0) + 1

    local permissions = state.pending_permissions or {}
    if #permissions > 0 and state.api_client then
      for _, permission in ipairs(permissions) do
        state.api_client:respond_to_permission(permission.sessionID, permission.id, { response = 'reject' })
      end
    end

    local ok, result = pcall(function()
      return state.api_client:abort_session(state.active_session.id):wait()
    end)

    if not ok then
      vim.notify('Abort error: ' .. vim.inspect(result), vim.log.levels.ERROR)
    end

    if vim.g.opencode_abort_count >= 3 then
      vim.notify('Re-starting Opencode server', vim.log.levels.WARN)
      vim.g.opencode_abort_count = 0
      if state.opencode_server then
        state.opencode_server:shutdown():await()
      end

      state.jobs.clear_server()
      state.jobs.set_server(server_job.ensure_server():await() --[[@as OpencodeServer]])
    end
  end

  if state.ui.is_visible() then
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
    state.jobs.set_opencode_cli_version(out:match('(%d+%%.%d+%%.%d+)') or out)
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

M._on_user_message_count_change = Promise.async(function(_, new, old)
  require('opencode.ui.renderer.flush').flush_pending_on_data_rendered()

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

M.handle_directory_change = Promise.async(function()
  local cwd = vim.fn.getcwd()
  log.debug('Working directory change %s', vim.inspect({ cwd = cwd }))
  vim.notify('Loading last session for new working dir [' .. cwd .. ']', vim.log.levels.INFO)

  state.session.clear_active()
  context.unload_attachments()

  state.session.set_active(session.get_last_workspace_session():await() or M.create_new_session():await())

  log.debug('Loaded session for new working dir ' .. vim.inspect({ session = state.active_session }))
end)

function M.paste_image_from_clipboard()
  return image_handler.paste_image_from_clipboard()
end

function M.setup()
  return true
end

return M
