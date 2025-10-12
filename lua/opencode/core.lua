-- This file was written by an automated tool.
local M = {}
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local server_job = require('opencode.server_job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local config = require('opencode.config')

---@param parent_id string?
function M.select_session(parent_id)
  local all_sessions = session.get_all_workspace_sessions() or {}
  local filtered_sessions = vim.tbl_filter(function(s)
    return s.description ~= '' and s ~= nil and s.parentID == parent_id
  end, all_sessions)

  ui.select_session(filtered_sessions, function(selected_session)
    if not selected_session then
      if state.windows then
        ui.focus_input()
      end
      return
    end
    state.active_session = selected_session
    if state.windows then
      state.restore_points = {}
      require('opencode.ui.streaming_renderer').reset()
      ui.render_output(true)
      ui.focus_input()
      ui.scroll_to_bottom()
    else
      M.open()
    end
  end)
end

---@param opts? OpenOpts
function M.open(opts)
  opts = opts or { focus = 'input', new_session = false }

  if not state.opencode_server_job or not state.opencode_server_job:is_running() then
    state.opencode_server_job = server_job.ensure_server() --[[@as OpencodeServer]]
  end

  local are_windows_closed = state.windows == nil

  if are_windows_closed then
    state.windows = ui.create_windows()
  end

  if opts.new_session then
    state.active_session = nil
    state.last_sent_context = nil
    state.active_session = M.create_new_session()
    ui.clear_output()
  else
    if not state.active_session then
      state.active_session = session.get_last_workspace_session()
    end

    if (are_windows_closed or ui.is_output_empty()) and not state.display_route then
      ui.render_output(true)
      ui.scroll_to_bottom()
    end
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed, start_insert = opts.start_insert == true })
  elseif opts.focus == 'output' then
    ui.focus_output({ restore_position = are_windows_closed })
  end
end

--- Sends a message to the active session, creating one if necessary.
--- @param prompt string The message prompt to send.
--- @param opts? SendMessageOpts
function M.send_message(prompt, opts)
  opts = opts or {}
  opts.context = opts.context or config.context
  opts.model = opts.model or state.current_model
  opts.agent = opts.agent or state.current_mode or config.default_mode

  local params = {}

  if opts.model then
    local provider, model = opts.model:match('^(.-)/(.+)$')
    params.model = { providerID = provider, modelID = model }
  end

  if opts.agent then
    params.agent = opts.agent
  end

  params.parts = context.format_message(prompt, opts.context)

  M.before_run(opts)

  state.api_client
    :create_message(state.active_session.id, params)
    :and_then(function(response)
      if not response or not response.info or not response.parts then
        -- fall back to full render. incremental render is handled
        -- event manager
        ui.render_output()
      end

      M.after_run(prompt)
    end)
    :catch(function(err)
      vim.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      M.stop()
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
end

---@param opts? SendMessageOpts
function M.before_run(opts)
  local is_new_session = opts and opts.new_session or not state.active_session
  opts = opts or {}

  M.stop()
  -- ui.clear_output()

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
      require('opencode.ui.topbar').render()
      ui.focus_input()
    else
      vim.notify('Changed provider to ' .. selection.display, vim.log.levels.INFO)
    end
  end)
end

function M.stop()
  if state.windows and state.active_session then
    if state.is_running() then
      vim.notify('Aborting current request...', vim.log.levels.WARN)
      state.api_client:abort_session(state.active_session.id):wait()
    end
    require('opencode.ui.footer').clear()
    -- ui.stop_render_output()
    -- require('opencode.ui.streaming_renderer').reset_and_render()
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

function M.setup()
  vim.schedule(function()
    M.opencode_ok()
  end)
  local OpencodeApiClient = require('opencode.api_client')
  state.api_client = OpencodeApiClient.new()
end

return M
