local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local input_window = require('opencode.ui.input_window')

local ui = require('opencode.ui.ui')
local icons = require('opencode.ui.icons')
local state = require('opencode.state')
local git_review = require('opencode.git_review')
local history = require('opencode.history')
local id = require('opencode.id')

local M = {}

function M.swap_position()
  require('opencode.ui.ui').swap_position()
end

function M.open_input()
  core.open({ new_session = false, focus = 'input', start_insert = true })
end

function M.open_input_new_session()
  core.open({ new_session = true, focus = 'input', start_insert = true })
end

function M.open_output()
  core.open({ new_session = false, focus = 'output' })
end

function M.close()
  if state.display_route then
    state.display_route = nil
    ui.clear_output()
    ui.render_output()
    ui.scroll_to_bottom()
    return
  end

  ui.close_windows(state.windows)
end

function M.toggle(new_session)
  if state.windows == nil then
    local focus = state.last_focused_opencode_window or 'input'

    core.open({ new_session = new_session == true, focus = focus, start_insert = false })
  else
    M.close()
  end
end

function M.toggle_focus(new_session)
  if not ui.is_opencode_focused() then
    local focus = state.last_focused_opencode_window or 'input'
    core.open({ new_session = new_session == true, focus = focus })
  else
    ui.return_to_last_code_win()
  end
end

function M.configure_provider()
  core.configure_provider()
end

function M.stop()
  core.stop()
end

---@param prompt string
---@param opts? SendMessageOpts
function M.run(prompt, opts)
  opts = vim.tbl_deep_extend('force', { new_session = false, focus = 'output' }, opts or {})
  core.send_message(prompt, opts)
end

---@param prompt string
---@param opts? SendMessageOpts
function M.run_new_session(prompt, opts)
  opts = vim.tbl_deep_extend('force', { new_session = true, focus = 'output' }, opts or {})
  core.send_message(prompt, { new_session = true, focus = 'output' })
end

---@param parent_id? string
function M.select_session(parent_id)
  core.select_session(parent_id)
end

function M.select_child_session()
  core.select_session(state.active_session and state.active_session.id or nil)
end

function M.toggle_pane()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
    return
  end

  ui.toggle_pane()
end

---@param from_snapshot_id? string
---@param to_snapshot_id? string|number
function M.diff_open(from_snapshot_id, to_snapshot_id)
  if not state.messages or not state.active_session then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.review(from_snapshot_id)
end

function M.diff_next()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.next_diff()
end

function M.diff_prev()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.prev_diff()
end

function M.diff_close()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.close_diff()
end

---@param from_snapshot_id? string
function M.diff_revert_all(from_snapshot_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.revert_all(from_snapshot_id)
end

---@param from_snapshot_id? string
---@param to_snapshot_id? string
function M.diff_revert_selected_file(from_snapshot_id, to_snapshot_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.revert_selected_file(from_snapshot_id)
end

---@param restore_point_id? string
function M.diff_restore_snapshot_file(restore_point_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.restore_snapshot_file(restore_point_id)
end

---@param restore_point_id? string
function M.diff_restore_snapshot_all(restore_point_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.restore_snapshot_all(restore_point_id)
end

function M.diff_revert_all_last_prompt()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  local snapshots = session.get_message_snapshot_ids(state.current_message)
  local snapshot_id = snapshots and snapshots[1]
  if not snapshot_id then
    vim.notify('No snapshots found for the current message', vim.log.levels.WARN)
    return
  end
  git_review.revert_all(snapshot_id)
end

function M.diff_revert_this(snapshot_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.revert_current(snapshot_id)
end

function M.diff_revert_this_last_prompt()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  local snapshots = session.get_message_snapshot_ids(state.current_message)
  local snapshot_id = snapshots and snapshots[1]
  if not snapshot_id then
    vim.notify('No snapshots found for the current message', vim.log.levels.WARN)
    return
  end
end

function M.set_review_breakpoint()
  vim.notify('Setting review breakpoint is not implemented yet', vim.log.levels.WARN)
  git_review.create_snapshot()
end

function M.prev_history()
  local prev_prompt = history.prev()
  if prev_prompt then
    input_window.set_content(prev_prompt)
    require('opencode.ui.mention').restore_mentions(state.windows.input_buf)
  end
end

function M.next_history()
  local next_prompt = history.next()
  if next_prompt then
    input_window.set_content(next_prompt)
    require('opencode.ui.mention').restore_mentions(state.windows.input_buf)
  end
end

function M.prev_prompt_history()
  local config = require('opencode.config')
  local key = config.get_key_for_function('input_window', 'prev_prompt_history')
  if key ~= '<up>' then
    return M.prev_history()
  end
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local at_boundary = current_line <= 1

  if at_boundary then
    return M.prev_history()
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
end

function M.next_prompt_history()
  local config = require('opencode.config')
  local key = config.get_key_for_function('input_window', 'next_prompt_history')
  if key ~= '<down>' then
    return M.next_history()
  end
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local at_boundary = current_line >= vim.api.nvim_buf_line_count(0)

  if at_boundary then
    return M.next_history()
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), 'n', false)
end

function M.next_message()
  require('opencode.ui.navigation').goto_next_message()
end

function M.prev_message()
  require('opencode.ui.navigation').goto_prev_message()
end

function M.submit_input_prompt()
  input_window.handle_submit()
end

function M.mention_file()
  local picker = require('opencode.ui.file_picker')
  local context = require('opencode.context')
  require('opencode.ui.mention').mention(function(mention_cb)
    picker.pick(function(file)
      mention_cb(file.path)
      context.add_file(file.path)
    end)
  end)
end

function M.mention()
  local config = require('opencode.config')
  local char = config.get_key_for_function('input_window', 'mention')
  ui.focus_input({ restore_position = true, start_insert = true })
  require('opencode.ui.completion').trigger_completion(char)()
end

function M.slash_commands()
  local config = require('opencode.config')
  local char = config.get_key_for_function('input_window', 'slash_commands')
  ui.focus_input({ restore_position = true, start_insert = true })
  require('opencode.ui.completion').trigger_completion(char)()
end

function M.focus_input()
  ui.focus_input({ restore_position = true, start_insert = true })
end

function M.debug_output()
  local config = require('opencode.config')
  if not config.debug.enabled then
    vim.notify('Debugging is not enabled in the config', vim.log.levels.WARN)
    return
  end
  local debug_helper = require('opencode.ui.debug_helper')
  debug_helper.debug_output()
end

function M.debug_message()
  local config = require('opencode.config')
  if not config.debug.enabled then
    vim.notify('Debugging is not enabled in the config', vim.log.levels.WARN)
    return
  end
  local debug_helper = require('opencode.ui.debug_helper')
  debug_helper.debug_message()
end

function M.debug_session()
  local config = require('opencode.config')
  if not config.debug.enabled then
    vim.notify('Debugging is not enabled in the config', vim.log.levels.WARN)
    return
  end
  local debug_helper = require('opencode.ui.debug_helper')
  debug_helper.debug_session()
end

function M.initialize()
  ui.render_output(true)

  local new_session = core.create_new_session('AGENTS.md Initialization')
  if not new_session then
    vim.notify('Failed to create new session', vim.log.levels.ERROR)
    return
  end
  local providerId, modelId = state.current_model:match('^(.-)/(.+)$')
  if not providerId or not modelId then
    vim.notify('Invalid model format: ' .. tostring(state.current_model), vim.log.levels.ERROR)
    return
  end
  state.active_session = new_session
  M.open_input()
  state.api_client:init_session(state.active_session.id, {
    providerID = providerId,
    modelID = modelId,
    messageID = id.ascending('message'),
  })
end

function M.agent_plan()
  state.current_mode = 'plan'
  require('opencode.ui.topbar').render()
end

function M.agent_build()
  state.current_mode = 'build'
  require('opencode.ui.topbar').render()
end

function M.select_agent()
  local modes = require('opencode.config_file').get_opencode_agents()
  vim.ui.select(modes, {
    prompt = 'Select mode:',
  }, function(selection)
    if not selection then
      return
    end

    state.current_mode = selection
    require('opencode.ui.topbar').render()
  end)
end

function M.switch_mode()
  local modes = require('opencode.config_file').get_opencode_agents()

  local current_index = util.index_of(modes, state.current_mode)

  if current_index == -1 then
    current_index = 0
  end

  -- Calculate next index, wrapping around if necessary
  local next_index = (current_index % #modes) + 1

  state.current_mode = modes[next_index]
  require('opencode.ui.topbar').render()
end

function M.with_header(lines, show_welcome)
  show_welcome = show_welcome or show_welcome
  state.display_route = '/header'

  local msg = {
    '## Opencode.nvim',
    '',
    '  █▀▀█ █▀▀█ █▀▀ █▀▀▄ █▀▀ █▀▀█ █▀▀▄ █▀▀',
    '  █░░█ █░░█ █▀▀ █░░█ █░░ █░░█ █░░█ █▀▀',
    '  ▀▀▀▀ █▀▀▀ ▀▀▀ ▀  ▀ ▀▀▀ ▀▀▀▀ ▀▀▀  ▀▀▀',
    '',
  }
  if show_welcome then
    table.insert(
      msg,
      'Welcome to Opencode.nvim! This plugin allows you to interact with AI models directly from Neovim.'
    )
    table.insert(msg, '')
  end

  for _, line in ipairs(lines) do
    table.insert(msg, line)
  end
  return msg
end

function M.help()
  state.display_route = '/help'
  M.open_input()
  local msg = M.with_header({
    '### Available Commands',
    '',
    '| Command   | Description         |',
    '|-----------|---------------------|',
  }, false)

  local max_desc_length = (vim.api.nvim_win_get_width(state.windows.output_win) / 2) - 5

  for _, def in pairs(M.commands) do
    local desc = def.desc or ''
    if #desc > max_desc_length then
      desc = desc:sub(1, max_desc_length - 3) .. '...'
    end
    table.insert(msg, string.format('| %-10s | %s |', def.name, desc))
  end

  table.insert(msg, '')
  ui.render_lines(msg)
end

function M.mcp()
  local info = require('opencode.config_file')
  local mcp = info.get_mcp_servers()
  if not mcp then
    ui.notify('No MCP configuration found. Please check your opencode config file.', 'warn')
    return
  end

  state.display_route = '/mcp'
  M.open_input()

  local msg = M.with_header({
    '### Available MCP servers',
    '',
    '| Name   | Type | cmd |',
    '|--------|------|-----|',
  })

  for name, def in pairs(mcp) do
    table.insert(
      msg,
      string.format(
        '| %s %-10s | %s | %s |',
        (def.enabled and icons.get('status_on') or icons.get('status_off')),
        name,
        def.type,
        table.concat(def.command, ' ')
      )
    )
  end

  table.insert(msg, '')
  ui.render_lines(msg)
end

--- Runs a user-defined command by name.
--- @param name string The name of the user command to run.
--- @param args? string[] Additional arguments to pass to the command.
function M.run_user_command(name, args)
  M.open_input()

  ui.render_output(true)
  state.api_client
    :send_command(state.active_session.id, {
      command = name,
      arguments = table.concat(args or {}, ' '),
    })
    :and_then(function()
      vim.schedule(function()
        require('opencode.history').write('/' .. name .. ' ' .. table.concat(args or {}, ' '))
      end)
    end)
end

--- Compacts the current session by removing unnecessary data.
--- @param current_session? Session The session to compact. Defaults to the active session.
function M.compact_session(current_session)
  current_session = current_session or state.active_session
  if not current_session then
    vim.notify('No active session to compact', vim.log.levels.WARN)
    return
  end

  ui.render_output(true)
  local providerId, modelId = state.current_model:match('^(.-)/(.+)$')
  state.api_client
    :summarize_session(current_session.id, {
      providerID = providerId,
      modelID = modelId,
    })
    :and_then(function()
      vim.schedule(function()
        vim.notify('Session compacted successfully', vim.log.levels.INFO)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to compact session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.share()
  if not state.active_session then
    vim.notify('No active session to share', vim.log.levels.WARN)
    return
  end

  ui.render_output(true)
  state.api_client
    :share_session(state.active_session.id)
    :and_then(function(response)
      vim.schedule(function()
        if response and response.share and response.share.url then
          vim.fn.setreg('+', response.share.url)
          vim.notify('Session link copied to clipboard successfully: ' .. response.share.url, vim.log.levels.INFO)
        else
          vim.notify('Session shared but no link received', vim.log.levels.WARN)
        end
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to share session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.unshare()
  if not state.active_session then
    vim.notify('No active session to unshare', vim.log.levels.WARN)
    return
  end

  ui.render_output(true)
  state.api_client
    :unshare_session(state.active_session.id)
    :and_then(function()
      vim.schedule(function()
        vim.notify('Session unshared successfully', vim.log.levels.INFO)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to unshare session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.undo()
  if not state.active_session then
    vim.notify('No active session to undo', vim.log.levels.WARN)
    return
  end

  local last_user_message = state.last_user_message
  if not last_user_message then
    vim.notify('No user message to undo', vim.log.levels.WARN)
    return
  end

  ui.render_output(true)
  state.api_client
    :revert_message(state.active_session.id, {
      messageID = last_user_message.id,
    })
    :and_then(function(response)
      state.active_session.revert = response.revert
      vim.schedule(function()
        vim.notify('Last message undone successfully', vim.log.levels.INFO)
        ui.render_output(true)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to undo last message: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.redo()
  if not state.active_session then
    vim.notify('No active session to undo', vim.log.levels.WARN)
    return
  end
  ui.render_output(true)

  state.api_client
    :unrevert_messages(state.active_session.id)
    :and_then(function(response)
      state.active_session.revert = response.revert
      vim.schedule(function()
        vim.notify('Last message rerterted successfully', vim.log.levels.INFO)
        ui.render_output(true)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to undo last message: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

---@param answer? 'once'|'always'|'reject'
function M.respond_to_permission(answer)
  answer = answer or 'once'
  if not state.current_permission then
    vim.notify('No permission request to accept', vim.log.levels.WARN)
    return
  end

  ui.render_output(true)
  state.api_client
    :respond_to_permission(state.current_permission.sessionID, state.current_permission.id, { response = answer })
    :and_then(function()
      vim.schedule(function()
        state.current_permission = nil
        ui.render_output(true)
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to reply to permission: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.permission_accept()
  M.respond_to_permission('once')
end

function M.permission_accept_all()
  M.respond_to_permission('always')
end

function M.permission_deny()
  M.respond_to_permission('reject')
end

-- Command def/compactinitions that call the API functions
M.commands = {
  swap_position = {
    name = 'OpencodeSwapPosition',
    desc = 'Swap Opencode pane left/right',
    fn = function()
      M.swap_position()
    end,
  },

  toggle = {
    name = 'Opencode',
    desc = 'Open opencode. Close if opened',
    fn = function()
      M.toggle()
    end,
  },

  toggle_focus = {
    name = 'OpencodeToggleFocus',
    desc = 'Toggle focus between opencode and last window',
    fn = function()
      M.toggle_focus()
    end,
  },

  open_input = {
    name = 'OpencodeOpenInput',
    desc = 'Opens and focuses on input window on insert mode',
    fn = function()
      M.open_input()
    end,
  },

  open_input_new_session = {
    name = 'OpencodeOpenInputNewSession',
    slash_cmd = '/new',
    desc = 'Opens and focuses on input window on insert mode. Creates a new session',
    fn = function()
      M.open_input_new_session()
    end,
  },

  open_output = {
    name = 'OpencodeOpenOutput',
    desc = 'Opens and focuses on output window',
    fn = function()
      M.open_output()
    end,
  },

  create_new_session = {
    name = 'OpencodeCreateNewSession',
    desc = 'Create a new opencode session',
    fn = function(opts)
      local title = opts.args and opts.args:match('^%s*(.+)')
      if title and title ~= '' then
        local new_session = core.create_new_session(title)
        if not new_session then
          vim.notify('Failed to create new session', vim.log.levels.ERROR)
          return
        end
        state.active_session = new_session
        M.open_input()
      else
        vim.notify('Session title cannot be empty', vim.log.levels.ERROR)
      end
    end,
    args = true,
  },

  close = {
    name = 'OpencodeClose',
    desc = 'Close UI windows',
    fn = function()
      M.close()
    end,
  },

  stop = {
    name = 'OpencodeStop',
    desc = 'Stop opencode while it is running',
    fn = function()
      M.stop()
    end,
  },

  select_session = {
    name = 'OpencodeSelectSession',
    slash_cmd = '/sessions',
    desc = 'Select and load a opencode session',
    fn = function()
      M.select_session()
    end,
  },

  select_child_session = {
    name = 'OpencodeSelectChildSession',
    slash_cmd = '/child-sessions',
    desc = 'Select and load a child session of the current session',
    fn = function()
      M.select_child_session()
    end,
  },

  toggle_pane = {
    name = 'OpencodeTogglePane',
    desc = 'Toggle between input and output panes',
    fn = function()
      M.toggle_pane()
    end,
  },

  configure_provider = {
    name = 'OpencodeConfigureProvider',
    slash_cmd = '/models',
    desc = 'Quick provider and model switch from predefined list',
    fn = function()
      M.configure_provider()
    end,
  },

  run = {
    name = 'OpencodeRun',
    desc = 'Run opencode with a prompt (continue last session)',
    fn = function(opts)
      local prompt, rest = opts.args:match('^(.-)%s+(%S+=%S.*)$')
      prompt = vim.trim(prompt or opts.args)
      local extra_args = util.parse_dot_args(rest or '')
      M.run(prompt, extra_args)
    end,
    args = true,
  },

  run_new_session = {
    name = 'OpencodeRunNewSession',
    desc = 'Run opencode with a prompt (new session)',
    fn = function(opts)
      local prompt, rest = opts.args:match('^(.-)%s+(%S+=%S.*)$')
      prompt = vim.trim(prompt or opts.args)
      local extra_args = util.parse_dot_args(rest or '')
      M.run_new_session(prompt, extra_args)
    end,
    args = true,
  },

  diff_open = {
    name = 'OpencodeDiff',
    desc = 'Opens a diff tab of a modified file since the last opencode prompt',
    fn = function()
      M.diff_open()
    end,
  },

  diff_next = {
    name = 'OpencodeDiffNext',
    desc = 'Navigate to next file diff',
    fn = function()
      M.diff_next()
    end,
  },

  diff_prev = {
    name = 'OpencodeDiffPrev',
    desc = 'Navigate to previous file diff',
    fn = function()
      M.diff_prev()
    end,
  },

  diff_close = {
    name = 'OpencodeDiffClose',
    desc = 'Close diff view tab and return to normal editing',
    fn = function()
      M.diff_close()
    end,
  },

  diff_revert_all_last_prompt = {
    name = 'OpencodeRevertAllLastPrompt',
    desc = 'Revert all file changes since the last opencode prompt',
    fn = function()
      M.diff_revert_all_last_prompt()
    end,
  },

  diff_revert_this_last_prompt = {
    name = 'OpencodeRevertThisLastPrompt',
    desc = 'Revert current file changes since the last opencode prompt',
    fn = function()
      M.diff_revert_this_last_prompt()
    end,
  },

  diff_revert_all_session = {
    name = 'OpencodeRevertAllSession',
    desc = 'Revert all file changes since the last session',
    fn = function()
      M.diff_revert_all_session()
    end,
  },

  diff_revert_this_session = {
    name = 'OpencodeRevertThisSession',
    desc = 'Revert current file changes since the last session',
    fn = function()
      M.diff_revert_this_session()
    end,
  },

  diff_revert_all_to_snapshot = {
    name = 'OpencodeRevertAllToSnapshot',
    desc = 'Revert all file changes to a specific snapshot',
    fn = function(snapshot)
      if not snapshot then
        vim.notify('Snapshot ID is required', vim.log.levels.ERROR)
        return
      end
      M.diff_revert_all(snapshot)
    end,
    args = true,
  },

  diff_revert_this_to_snapshot = {
    name = 'OpencodeRevertThisToSnapshot',
    desc = 'Revert all file changes to a specific snapshot',
    fn = function(snapshot)
      if not snapshot then
        vim.notify('Snapshot ID is required', vim.log.levels.ERROR)
        return
      end
      M.diff_revert_this(snapshot)
    end,
    args = true,
  },

  diff_restore_snapshot_file = {
    name = 'OpencodeRestoreSnapshotFile',
    desc = 'Restore a file to a specific restore point',
    fn = function(snapshot)
      if not snapshot then
        vim.notify('Snapshot ID is required', vim.log.levels.ERROR)
        return
      end
      M.diff_restore_snapshot_file(snapshot)
    end,
    args = true,
  },

  diff_restore_snapshot_all = {
    name = 'OpencodeRestoreSnapshotAll',
    desc = 'Restore all files to a specific restore point',
    fn = function(snapshot)
      if not snapshot then
        vim.notify('Snapshot ID is required', vim.log.levels.ERROR)
        return
      end
      M.diff_restore_snapshot_all(snapshot)
    end,
    args = true,
  },

  set_review_breakpoint = {
    name = 'OpencodeSetReviewBreakpoint',
    desc = 'Set a review breakpoint to track changes',
    fn = function()
      M.set_review_breakpoint()
    end,
  },

  init = {
    name = 'OpencodeInit',
    slash_cmd = '/init',
    desc = 'Initialize/Update AGENTS.md file',
    fn = function()
      M.initialize()
    end,
  },

  help = {
    name = 'OpencodeHelp',
    slash_cmd = '/help',
    desc = 'Display help message',
    fn = function()
      M.help()
    end,
  },

  mcp = {
    name = 'OpencodeMCP',
    slash_cmd = '/mcp',
    desc = 'Display list of mcp servers',
    fn = function()
      M.mcp()
    end,
  },

  opencode_mode_plan = {
    name = 'OpencodeAgentPlan',
    desc = 'Set opencode agent to `plan`. (Tool calling disabled. No editor context besides selections)',
    fn = function()
      M.agent_plan()
    end,
  },

  opencode_mode_build = {
    name = 'OpencodeAgentBuild',
    desc = 'Set opencode agent to `build`. (Default with full agent capabilities)',
    fn = function()
      M.agent_build()
    end,
  },

  open_code_select_mode = {
    name = 'OpencodeAgentSelect',
    slash_cmd = '/agent',
    desc = 'Select opencode agent',
    fn = function()
      M.select_agent()
    end,
  },

  run_user_command = {
    name = 'OpencodeRunUserCommand',
    desc = 'Run a user-defined Opencode command by name',
    fn = function(opts)
      local parts = vim.split(opts.args or '', '%s+')
      local name = parts[1]
      if not name or name == '' then
        vim.notify('User command name required. Usage: :OpencodeRunUserCommand <name>', vim.log.levels.ERROR)
        return
      end
      M.run_user_command(name, vim.list_slice(parts, 2))
    end,
    args = true,
  },

  compact_session = {
    name = 'OpencodeCompactSession',
    desc = 'Compacts the current session by removing unnecessary data',
    fn = function()
      if not state.active_session then
        vim.notify('No active session to compact', vim.log.levels.WARN)
        return
      end
      M.compact_session(state.active_session)
    end,
    slash_cmd = '/compact',
  },

  share_session = {
    name = 'OpencodeShareSession',
    desc = 'Share the current session and get a shareable link',
    fn = function()
      if not state.active_session then
        vim.notify('No active session to share', vim.log.levels.WARN)
        return
      end
      M.share()
    end,
    slash_cmd = '/share',
  },

  unshare_session = {
    name = 'OpencodeUnshareSession',
    desc = 'Unshare the current session, disabling the shareable link',
    fn = function()
      if not state.active_session then
        vim.notify('No active session to unshare', vim.log.levels.WARN)
        return
      end
      M.unshare()
    end,
    slash_cmd = '/unshare',
  },

  undo = {
    name = 'OpencodeUndo',
    desc = 'Undo last opencode action',
    fn = function()
      if not state.active_session then
        vim.notify('No active session to undo', vim.log.levels.WARN)
        return
      end
      M.undo()
    end,
    slash_cmd = '/undo',
  },

  redo = {
    name = 'OpencodeRedo',
    desc = 'Redo last opencode action',
    fn = function()
      if not state.active_session then
        vim.notify('No active session to undo', vim.log.levels.WARN)
        return
      end
      M.redo()
    end,
    slash_cmd = '/redo',
  },

  permission_accept = {
    name = 'OpencodePermissionAccept',
    desc = 'Accept current permission request',
    fn = function()
      M.respond_to_permission('once')
    end,
  },

  permission_accept_all = {
    name = 'OpencodePermissionAcceptAll',
    desc = 'Accept all permission requests',
    fn = function()
      M.respond_to_permission('always')
    end,
  },

  permission_deny = {
    name = 'OpencodePermissionDeny',
    desc = 'Deny current permission request',
    fn = function()
      M.respond_to_permission('reject')
    end,
  },
}

---@return OpencodeSlashCommand[]
function M.get_slash_commands()
  local commands = vim.tbl_filter(function(cmd)
    return cmd.slash_cmd and cmd.slash_cmd ~= ''
  end, M.commands)

  local user_commands = require('opencode.config_file').get_user_commands()
  if user_commands then
    for name, cfg in pairs(user_commands) do
      table.insert(commands, {
        slash_cmd = '/' .. name,
        desc = 'Run user command: ' .. name,
        args = cfg.template and cfg.template:match('$ARGUMENTS') ~= nil,
        fn = function(args)
          M.run_user_command(name, args)
        end,
      })
    end
  end

  table.sort(commands, function(a, b)
    return a.slash_cmd < b.slash_cmd
  end)

  return commands
end

function M.setup()
  for _, cmd in pairs(M.commands) do
    vim.api.nvim_create_user_command(cmd.name, cmd.fn, {
      desc = cmd.desc,
      nargs = cmd.args and '+' or 0,
    })
  end
end

return M
