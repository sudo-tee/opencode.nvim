local M = {}
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local server_job = require('opencode.server_job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local config = require('opencode.config').get()

function M.select_session()
  local all_sessions = session.get_all_workspace_sessions() or {}
  local filtered_sessions = vim.tbl_filter(function(s)
    return s.description ~= '' and s ~= nil
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
      ui.render_output(true)
      ui.scroll_to_bottom()
      ui.focus_input()
    else
      M.open()
    end
  end)
end

---@param opts? OpenOpts
function M.open(opts)
  opts = opts or { focus = 'input', new_session = false }

  if not M.opencode_ok() then
    return
  end

  local are_windows_closed = state.windows == nil

  if are_windows_closed then
    state.windows = ui.create_windows()
  end

  if opts.new_session then
    state.active_session = nil
    state.last_sent_context = nil
    ui.clear_output()
  else
    if not state.active_session then
      state.active_session = session.get_last_workspace_session()
    end

    if (are_windows_closed or ui.is_output_empty()) and not state.display_route then
      ui.render_output()
      ui.scroll_to_bottom()
    end
  end

  if opts.focus == 'input' then
    ui.focus_input({ restore_position = are_windows_closed })
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

  if not state.active_session or opts.new_session then
    state.active_session = M.create_new_session(nil):wait()
  end

  params.parts = context.format_message(prompt, opts.context)
  M.run_server_api('/session/' .. state.active_session.name .. '/message', 'POST', params, {
    on_done = function()
      M.after_run(prompt)
    end,
    on_error = function(err)
      vim.notify('Error sending message to session: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end,
  })
end

---@param title? string
---@param cb fun(session: Session)?
---@return Promise<Session>
function M.create_new_session(title, cb)
  ---@type Promise<Session>
  local promise = Promise.new()
  M.run_server_api('/session', 'POST', title and { title = title } or false, {
    on_error = function(err)
      promise:reject(err)
      vim.notify(vim.inspect(err), vim.log.levels.ERROR)
    end,
    on_done = function(data)
      if data and data.id then
        local new_session = session.get_by_name(data.id)
        if new_session then
          if cb then
            cb(new_session)
          end
          promise:resolve(new_session)
          return
        end
      else
        vim.notify('Failed to create new session: Invalid response from server', vim.log.levels.ERROR)
      end
    end,
  })
  return promise
end

---@param prompt string
function M.after_run(prompt)
  context.unload_attachments()
  state.last_sent_context = vim.deepcopy(context.context)
  ui.focus_output()
  require('opencode.history').write(prompt)

  if state.windows then
    ui.render_output()
  end
end

---@param opts? SendMessageOpts
function M.before_run(opts)
  local is_new_session = opts and opts.new_session or not state.active_session
  M.stop()

  if is_new_session then
    ui.clear_output()
  end

  opts = opts or {}

  M.open({
    new_session = is_new_session,
  })
end

---@param endpoint string
---@param method string
---@param body table|nil|boolean
---@param opts? {cwd: string, background: boolean, on_done: fun(result: any), on_error: fun(err: any)}
function M.run_server_api(endpoint, method, body, opts)
  opts = opts or {}
  if not opts.background then
    M.before_run(opts)
  end

  state.opencode_server_job = server_job.run(endpoint, method, body, {
    cwd = opts.cwd,
    on_ready = function(_)
      state.last_output = os.time()
      ui.render_output()
    end,
    on_done = function(result)
      state.was_interrupted = false
      state.opencode_server_job = nil
      state.last_output = os.time()
      ui.render_output()
      util.safe_call(opts.on_done, result)
    end,
    on_error = function(err)
      state.opencode_server_job = nil
      state.last_output = os.time()
      ui.render_output()
      vim.notify(err.message, vim.log.levels.ERROR)
      util.safe_call(opts.on_error, err)
    end,
    on_exit = function()
      state.opencode_server_job = nil
      state.last_output = os.time()
      ui.render_output()
    end,
    on_interrupt = function()
      state.opencode_server_job = nil
      state.was_interrupted = true
      state.last_output = os.time()
      ui.render_output()
      vim.notify('Opencode server API call interrupted by user', vim.log.levels.WARN)
    end,
  })

  state.was_interrupted = false
end

function M.add_file_to_context()
  local picker = require('opencode.ui.file_picker')
  require('opencode.ui.mention').mention(function(mention_cb)
    picker.pick(function(file)
      mention_cb(file.name)
      context.add_file(file.path)
    end)
  end)
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
  if state.opencode_server_job then
    state.opencode_server_job:shutdown()
    state.opencode_server_job:get_interrupt_promise():wait()
  end
  state.opencode_server_job = nil

  if state.windows then
    require('opencode.ui.footer').clear()
    ui.stop_render_output()
    ui.render_output()
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

--- Parse arguments in the form of key=value, supporting dot notation for nested tables.
--- Example: "context.selection.enabled=false options
function M.parse_dot_args(args_str)
  local result = {}
  for arg in string.gmatch(args_str, '[^%s]+') do
    local key, value = arg:match('([^=]+)=([^=]+)')
    if key and value then
      local parts = vim.split(key, '.', { plain = true })
      local t = result
      for i = 1, #parts - 1 do
        t[parts[i]] = t[parts[i]] or {}
        t = t[parts[i]]
      end
      -- Convert value to boolean if possible
      if value == 'true' then
        value = true
      elseif value == 'false' then
        value = false
      elseif tonumber(value) then
        value = tonumber(value)
      end
      t[parts[#parts]] = value
    end
  end
  return result
end

return M
