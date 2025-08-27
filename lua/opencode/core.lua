local M = {}
local state = require('opencode.state')
local context = require('opencode.context')
local session = require('opencode.session')
local ui = require('opencode.ui.ui')
local job = require('opencode.job')
local input_window = require('opencode.ui.input_window')
local util = require('opencode.util')

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
      ui.render_output()
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

---@param prompt string
---@param opts? RunOpts
function M.run(prompt, opts)
  if not M.opencode_ok() then
    return false
  end
  M.before_run(opts)

  -- Add small delay to ensure stop is complete
  vim.defer_fn(function()
    job.execute(prompt, {
      on_start = function()
        state.was_interrupted = false
        M.after_run(prompt)
      end,
      on_output = function(output)
        vim.cmd('checktime')

        if output and not state.active_session then
          local found = string.match(output, 'sessionID=(ses_%w+)')
          if found then
            state.active_session = session.get_by_name(found)
            state.new_session_name = found
          end
        end
        state.last_output = os.time()
        ui.render_output()
      end,
      on_error = function(err)
        vim.notify(err, vim.log.levels.ERROR)

        ui.close_windows(state.windows)
      end,
      on_exit = function()
        state.opencode_run_job = nil
        state.last_output = os.time()
        ui.render_output()
      end,
      on_interrupt = function()
        state.opencode_run_job = nil
        state.was_interrupted = true
        state.last_output = os.time()

        ui.render_output()
        vim.notify('Opencode run interrupted by user', vim.log.levels.WARN)
      end,
    }, opts and { no_context = opts.no_context or false, model = opts.model, agent = opts.agent } or nil)
  end, 10)
end

function M.after_run(prompt)
  context.unload_attachments()
  state.last_sent_context = vim.deepcopy(context.context)
  require('opencode.history').write(prompt)

  if state.windows then
    ui.render_output()
  end
end

---@param opts? RunOpts
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

local server_job = require('opencode.server_job')

---@param endpoint string
---@param method string
---@param body table|nil
---@param opts? {cwd: string, background: boolean, on_done: fun(result: any), on_error: fun(err: any)}
function M.run_server_api(endpoint, method, body, opts)
  if state.opencode_server_job then
    return
  end

  opts = opts or {}
  if not opts.background then
    M.before_run(opts)
  end

  state.opencode_server_job = server_job.run(endpoint, method, body, {
    cwd = opts.cwd,
    on_ready = function(_, url)
      state.last_output = os.time()
      ui.render_output()
    end,
    on_done = function(result)
      state.opencode_server_job = nil
      state.last_output = os.time()
      ui.render_output()
      util.safe_call(opts.on_done, result)
    end,
    on_error = function(err)
      state.opencode_server_job = nil
      state.last_output = os.time()
      ui.render_output()
      vim.notify(err, vim.log.levels.ERROR)
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
  M.after_run(endpoint)
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

function M.select_slash_commands()
  local custom_command_key = require('opencode.config').get('keymap').window.slash_commands
  if not input_window.is_empty() then
    if #custom_command_key == 1 then
      vim.api.nvim_feedkeys(custom_command_key, 'n', false)
    end
    return
  end

  local api = require('opencode.api')
  local commands = api.get_slash_commands() or {}

  local cmd_len = 0
  for _, cmd in ipairs(commands) do
    cmd_len = math.max(cmd_len, #cmd.slash_cmd)
  end

  vim.ui.select(commands, {
    prompt = 'Select command:',
    format_item = function(item)
      return string.format('%-' .. cmd_len .. 's │ %s', item.slash_cmd, item.desc)
    end,
  }, function(selection)
    if selection and selection.fn then
      selection.fn()
    else
      if #custom_command_key == 1 then
        vim.cmd('startinsert')
        vim.api.nvim_feedkeys(custom_command_key, 'n', false)
      end
    end
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
  if state.opencode_run_job then
    job.stop(state.opencode_run_job)
  end
  state.opencode_run_job = nil
  if state.windows then
    ui.stop_render_output()
    ui.render_output()
    input_window.set_content('')
    require('opencode.history').index = nil
    ui.focus_input()
  end
end

---@param version string
---@return number|nil, number|nil, number|nil
local function parse_semver(version)
  if not version or version == '' then
    return nil
  end
  local major, minor, patch = version:match('(%d+)%.(%d+)%.?(%d*)')
  if not major then
    return nil
  end
  return tonumber(major) or 0, tonumber(minor) or 0, tonumber(patch) or 0
end

---@param version string
---@param required_version string
---@return boolean
local function is_version_greater_or_equal(version, required_version)
  local major, minor, patch = parse_semver(version)
  local req_major, req_minor, req_patch = parse_semver(required_version)
  if not major or not req_major then
    return false
  end
  if major ~= req_major then
    return major > req_major
  end
  if minor ~= req_minor then
    return minor > req_minor
  end
  return patch >= req_patch
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

  if not is_version_greater_or_equal(current_version, required) then
    vim.notify(
      string.format('Unsupported opencode CLI version: %s. Requires >= %s', current_version, required),
      vim.log.levels.ERROR
    )
    return false
  end

  return true
end

return M
