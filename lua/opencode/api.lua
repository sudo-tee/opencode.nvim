local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local config_file = require('opencode.config_file')
local state = require('opencode.state')

local input_window = require('opencode.ui.input_window')
local ui = require('opencode.ui.ui')
local icons = require('opencode.ui.icons')
local git_review = require('opencode.git_review')
local history = require('opencode.history')

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
    -- need to trigger a re-render here to re-display the session
    ui.render_output()
    return
  end

  ui.close_windows(state.windows)
end

function M.toggle(new_session)
  if state.windows == nil then
    local focus = state.last_focused_opencode_window or 'input' ---@cast focus 'input' | 'output'
    core.open({ new_session = new_session == true, focus = focus, start_insert = false })
  else
    M.close()
  end
end

function M.toggle_focus(new_session)
  if not ui.is_opencode_focused() then
    local focus = state.last_focused_opencode_window or 'input' ---@cast focus 'input' | 'output'
    core.open({ new_session = new_session == true, focus = focus })
  else
    ui.return_to_last_code_win()
  end
end

function M.configure_provider()
  core.configure_provider()
end

function M.cancel()
  core.cancel()
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
  core.send_message(prompt, opts)
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
  if not state.windows then
    return
  end
  local prev_prompt = history.prev()
  if prev_prompt then
    input_window.set_content(prev_prompt)
    require('opencode.ui.mention').restore_mentions(state.windows.input_buf)
  end
end

function M.next_history()
  if not state.windows then
    return
  end
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
  if state.display_route then
    -- we're displaying /help or something similar, need to clear that and refresh
    -- the session data before sending the command
    state.display_route = nil
    ui.render_output(true)
  end

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

  ui.focus_input({ restore_position = false, start_insert = true })
  require('opencode.ui.completion').trigger_completion(char)()
end

function M.context_items()
  local config = require('opencode.config')
  local char = config.get_key_for_function('input_window', 'context_items')
  ui.focus_input({ restore_position = true, start_insert = true })
  require('opencode.ui.completion').trigger_completion(char)()
end

function M.slash_commands()
  local config = require('opencode.config')
  local char = config.get_key_for_function('input_window', 'slash_commands')
  ui.focus_input({ restore_position = false, start_insert = true })
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
  local id = require('opencode.id')

  local new_session = core.create_new_session('AGENTS.md Initialization')
  if not new_session then
    vim.notify('Failed to create new session', vim.log.levels.ERROR)
    return
  end
  if not core.initialize_current_model() or not state.current_model then
    vim.notify('No model selected', vim.log.levels.ERROR)
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
  require('opencode.core').switch_to_mode('plan')
end

function M.agent_build()
  require('opencode.core').switch_to_mode('build')
end

function M.select_agent()
  local modes = config_file.get_opencode_agents()
  vim.ui.select(modes, {
    prompt = 'Select mode:',
  }, function(selection)
    if not selection then
      return
    end

    require('opencode.core').switch_to_mode(selection)
  end)
end

function M.switch_mode()
  local modes = config_file.get_opencode_agents() --[[@as string[] ]]

  local current_index = util.index_of(modes, state.current_mode)

  if current_index == -1 then
    current_index = 0
  end

  -- Calculate next index, wrapping around if necessary
  local next_index = (current_index % #modes) + 1

  require('opencode.core').switch_to_mode(modes[next_index])
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
    'Use `:Opencode <subcommand>` to run commands. Examples:',
    '',
    '- `:Opencode open input` - Open the input window',
    '- `:Opencode session new` - Create a new session',
    '- `:Opencode diff open` - Open diff view',
    '',
    '### Subcommands',
    '',
    '| Command      | Description |',
    '|--------------|-------------|',
  }, false)

  if not state.windows or not state.windows.output_win then
    return
  end

  local max_desc_length = vim.api.nvim_win_get_width(state.windows.output_win) - 22

  local sorted_commands = vim.tbl_keys(M.commands)
  table.sort(sorted_commands)

  for _, name in ipairs(sorted_commands) do
    local def = M.commands[name]
    local desc = def.desc or ''
    if #desc > max_desc_length then
      desc = desc:sub(1, max_desc_length - 3) .. '...'
    end
    table.insert(msg, string.format('| %-12s | %-' .. max_desc_length .. 's |', name, desc))
  end

  table.insert(msg, '')
  table.insert(msg, 'For slash commands (e.g., /models, /help), type `/` in the input window.')
  table.insert(msg, '')
  ui.render_lines(msg)
end

function M.mcp()
  local mcp = config_file.get_mcp_servers()
  if not mcp then
    vim.notify('No MCP configuration found. Please check your opencode config file.', vim.log.levels.WARN)
    return
  end

  state.display_route = '/mcp'
  M.open_input()

  local msg = M.with_header({
    '### Available MCP servers',
    '',
    '| Name   | Type | cmd/url |',
    '|--------|------|---------|',
  })

  for name, def in pairs(mcp) do
    local cmd_or_url
    if def.type == 'local' then
      cmd_or_url = def.command and table.concat(def.command, ' ')
    elseif def.type == 'remote' then
      cmd_or_url = def.url
    end

    table.insert(
      msg,
      string.format(
        '| %s %-10s | %s | %s |',
        (def.enabled and icons.get('status_on') or icons.get('status_off')),
        name,
        def.type,
        cmd_or_url
      )
    )
  end

  table.insert(msg, '')
  ui.render_lines(msg)
end

function M.commands_list()
  local commands = config_file.get_user_commands()
  if not commands then
    vim.notify('No user commands found. Please check your opencode config file.', vim.log.levels.WARN)
    return
  end

  state.display_route = '/commands'
  M.open_input()

  local msg = M.with_header({
    '### Available User Commands',
    '',
    '| Name | Description |Arguments|',
    '|------|-------------|---------|',
  })

  for name, def in pairs(commands) do
    local desc = def.description or ''
    table.insert(msg, string.format('| %s | %s | %s |', name, desc, tostring(config_file.command_takes_arguments(def))))
  end

  table.insert(msg, '')
  ui.render_lines(msg)
end

function M.current_model()
  return core.initialize_current_model()
end

--- Runs a user-defined command by name.
--- @param name string The name of the user command to run.
--- @param args? string[] Additional arguments to pass to the command.
function M.run_user_command(name, args)
  M.open_input()

  if not state.active_session then
    vim.notify('No active session', vim.log.levels.WARN)
    return
  end
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

  local current_model = state.current_model
  if not current_model then
    vim.notify('No model selected', vim.log.levels.ERROR)
    return
  end
  local providerId, modelId = current_model:match('^(.-)/(.+)$')
  if not providerId or not modelId then
    vim.notify('Invalid model format: ' .. tostring(current_model), vim.log.levels.ERROR)
    return
  end
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

  state.api_client
    :unshare_session(state.active_session.id)
    :and_then(function(response)
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

---@param messageId? string
function M.undo(messageId)
  if not state.active_session then
    vim.notify('No active session to undo', vim.log.levels.WARN)
    return
  end

  local message_to_revert = messageId or state.last_user_message and state.last_user_message.info.id
  if not message_to_revert then
    vim.notify('No user message to undo', vim.log.levels.WARN)
    return
  end

  state.api_client
    :revert_message(state.active_session.id, {
      messageID = message_to_revert,
    })
    :and_then(function(response)
      vim.schedule(function()
        vim.cmd('checktime')
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to undo last message: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

function M.timeline()
  local user_messages = {}
  for _, msg in ipairs(state.messages or {}) do
    local parts = msg.parts or {}
    local is_summary = #parts == 1 and parts[1].synthetic == true
    if msg.info.role == 'user' and not is_summary then
      table.insert(user_messages, msg)
    end
  end
  if #user_messages == 0 then
    vim.notify('No user messages in the current session', vim.log.levels.WARN)
    return
  end

  local timeline_picker = require('opencode.ui.timeline_picker')
  timeline_picker.pick(user_messages, function(selected_msg)
    if selected_msg then
      require('opencode.ui.navigation').goto_message_by_id(selected_msg.info.id)
    end
  end)
end

--- Forks the current session from a specific user message.
---@param message_id? string The ID of the user message to fork from. If not provided, uses the last user message.
function M.fork_session(message_id)
  if not state.active_session then
    vim.notify('No active session to fork', vim.log.levels.WARN)
    return
  end

  local message_to_fork = message_id or state.last_user_message and state.last_user_message.info.id
  if not message_to_fork then
    vim.notify('No user message to fork from', vim.log.levels.WARN)
    return
  end

  state.api_client
    :fork_session(state.active_session.id, {
      messageID = message_to_fork,
    })
    :and_then(function(response)
      vim.schedule(function()
        if response and response.id then
          vim.notify('Session forked successfully. New session ID: ' .. response.id, vim.log.levels.INFO)
          core.switch_session(response.id)
        else
          vim.notify('Session forked but no new session ID received', vim.log.levels.WARN)
        end
      end)
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to fork session: ' .. vim.inspect(err), vim.log.levels.ERROR)
      end)
    end)
end

-- Returns the ID of the next user message after the current undo point
-- This is a port of the opencode tui logic
-- https://github.com/sst/opencode/blob/dev/packages/tui/internal/components/chat/messages.go#L1199
function find_next_message_for_redo()
  if not state.active_session then
    return nil
  end

  local revert_time = 0
  local revert = state.active_session.revert

  if not revert then
    return nil
  end

  for _, message in ipairs(state.messages or {}) do
    if message.info.id == revert.messageID then
      revert_time = math.floor(message.info.time.created)
      break
    end
    if revert.partID and revert.partID ~= '' then
      for _, part in ipairs(message.parts) do
        if part.id == revert.partID and part.state and part.state.time then
          revert_time = math.floor(part.state.time.start)
          break
        end
      end
    end
  end

  -- Find next user message after revert time
  local next_message_id = nil
  for _, msg in ipairs(state.messages or {}) do
    if msg.info.role == 'user' and msg.info.time.created > revert_time then
      next_message_id = msg.info.id
      break
    end
  end
  return next_message_id
end

function M.redo()
  if not state.active_session then
    vim.notify('No active session to redo', vim.log.levels.WARN)
    return
  end

  if not state.active_session.revert or state.active_session.revert.messageID == '' then
    vim.notify('Nothing to redo', vim.log.levels.WARN)
    return
  end

  if not state.messages then
    return
  end

  local next_message_id = find_next_message_for_redo()
  if not next_message_id then
    state.api_client
      :unrevert_messages(state.active_session.id)
      :and_then(function(response)
        vim.schedule(function()
          vim.cmd('checktime')
        end)
      end)
      :catch(function(err)
        vim.schedule(function()
          vim.notify('Failed to redo message: ' .. vim.inspect(err), vim.log.levels.ERROR)
        end)
      end)
  else
    -- Calling revert on a "later" message is like a redo
    state.api_client
      :revert_message(state.active_session.id, {
        messageID = next_message_id,
      })
      :and_then(function(response)
        vim.schedule(function()
          vim.cmd('checktime')
        end)
      end)
      :catch(function(err)
        vim.schedule(function()
          vim.notify('Failed to redo message: ' .. vim.inspect(err), vim.log.levels.ERROR)
        end)
      end)
  end
end

---@param answer? 'once'|'always'|'reject'
function M.respond_to_permission(answer)
  answer = answer or 'once'
  if not state.current_permission then
    vim.notify('No permission request to accept', vim.log.levels.WARN)
    return
  end

  state.api_client
    :respond_to_permission(state.current_permission.sessionID, state.current_permission.id, { response = answer })
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

M.commands = {
  open = {
    desc = 'Open opencode window (input/output)',
    completions = { 'input', 'output' },
    fn = function(args)
      local target = args[1] or 'input'
      if target == 'input' then
        M.open_input()
      elseif target == 'output' then
        M.open_output()
      else
        vim.notify('Invalid target. Use: input or output', vim.log.levels.ERROR)
      end
    end,
  },

  close = {
    desc = 'Close opencode windows',
    fn = function(args)
      M.close()
    end,
  },

  cancel = {
    desc = 'Cancel running request',
    fn = M.cancel,
  },

  toggle = {
    desc = 'Toggle opencode windows',
    fn = M.toggle,
  },

  toggle_focus = {
    desc = 'Toggle focus between opencode and code',
    fn = M.toggle_focus,
  },

  toggle_pane = {
    desc = 'Toggle between input/output panes',
    fn = M.toggle_pane,
  },

  swap = {
    desc = 'Swap pane position left/right',
    fn = M.swap_position,
  },

  session = {
    desc = 'Manage sessions (new/select/child/compact/share/unshare)',
    completions = { 'new', 'select', 'child', 'compact', 'share', 'unshare', 'agents_init' },
    fn = function(args)
      local subcmd = args[1]
      if subcmd == 'new' then
        local title = table.concat(vim.list_slice(args, 2), ' ')
        if title and title ~= '' then
          local new_session = core.create_new_session(title)
          if not new_session then
            vim.notify('Failed to create new session', vim.log.levels.ERROR)
            return
          end
          state.active_session = new_session
          M.open_input()
        else
          M.open_input_new_session()
        end
      elseif subcmd == 'select' then
        M.select_session()
      elseif subcmd == 'child' then
        M.select_child_session()
      elseif subcmd == 'compact' then
        M.compact_session()
      elseif subcmd == 'share' then
        M.share()
      elseif subcmd == 'unshare' then
        M.unshare()
      elseif subcmd == 'agents_init' then
        M.initialize()
      else
        local valid_subcmds = table.concat(M.commands.session.completions, ', ')
        vim.notify('Invalid session subcommand. Use: ' .. valid_subcmds, vim.log.levels.ERROR)
      end
    end,
  },

  undo = {
    desc = 'Undo last action',
    fn = M.undo,
  },

  redo = {
    desc = 'Redo last action',
    fn = M.redo,
  },

  diff = {
    desc = 'View file diffs (open/next/prev/close)',
    completions = { 'open', 'next', 'prev', 'close' },
    fn = function(args)
      local subcmd = args[1]
      if not subcmd or subcmd == 'open' then
        M.diff_open()
      elseif subcmd == 'next' then
        M.diff_next()
      elseif subcmd == 'prev' then
        M.diff_prev()
      elseif subcmd == 'close' then
        M.diff_close()
      else
        local valid_subcmds = table.concat(M.commands.diff.completions, ', ')
        vim.notify('Invalid diff subcommand. Use: ' .. valid_subcmds, vim.log.levels.ERROR)
      end
    end,
  },

  revert = {
    desc = 'Revert changes (all/this, prompt/session)',
    completions = { 'all', 'this' },
    sub_completions = { 'prompt', 'session' },
    fn = function(args)
      local scope = args[1]
      local target = args[2]

      if scope == 'all' then
        if target == 'prompt' then
          M.diff_revert_all_last_prompt()
        elseif target == 'session' then
          M.diff_revert_all(nil)
        elseif target then
          M.diff_revert_all(target)
        else
          vim.notify('Invalid revert target. Use: prompt, session, or <snapshot_id>', vim.log.levels.ERROR)
        end
      elseif scope == 'this' then
        if target == 'prompt' then
          M.diff_revert_this_last_prompt()
        elseif target == 'session' then
          M.diff_revert_this(nil)
        elseif target then
          M.diff_revert_this(target)
        else
          vim.notify('Invalid revert target. Use: prompt, session, or <snapshot_id>', vim.log.levels.ERROR)
        end
      else
        vim.notify('Invalid revert scope. Use: all or this', vim.log.levels.ERROR)
      end
    end,
  },

  restore = {
    desc = 'Restore from snapshot (file/all)',
    completions = { 'file', 'all' },
    fn = function(args)
      local scope = args[1]
      local snapshot_id = args[2]

      if not snapshot_id then
        vim.notify('Snapshot ID required', vim.log.levels.ERROR)
        return
      end

      if scope == 'file' then
        M.diff_restore_snapshot_file(snapshot_id)
      elseif scope == 'all' then
        M.diff_restore_snapshot_all(snapshot_id)
      else
        vim.notify('Invalid restore scope. Use: file or all', vim.log.levels.ERROR)
      end
    end,
  },

  breakpoint = {
    desc = 'Set review breakpoint',
    fn = M.set_review_breakpoint,
  },

  agent = {
    desc = 'Manage agents (plan/build/select)',
    completions = { 'plan', 'build', 'select' },
    fn = function(args)
      local subcmd = args[1]
      if subcmd == 'plan' then
        M.agent_plan()
      elseif subcmd == 'build' then
        M.agent_build()
      elseif subcmd == 'select' then
        M.select_agent()
      else
        local valid_subcmds = table.concat(M.commands.agent.completions, ', ')
        vim.notify('Invalid agent subcommand. Use: ' .. valid_subcmds, vim.log.levels.ERROR)
      end
    end,
  },

  models = {
    desc = 'Switch provider/model',
    fn = M.configure_provider,
  },

  run = {
    desc = 'Run prompt in current session',
    fn = function(args)
      local opts, prompt = util.parse_run_args(args)
      if prompt == '' then
        vim.notify('Prompt required', vim.log.levels.ERROR)
        return
      end
      M.run(prompt, opts)
    end,
  },

  run_new = {
    desc = 'Run prompt in new session',
    fn = function(args)
      local opts, prompt = util.parse_run_args(args)
      if prompt == '' then
        vim.notify('Prompt required', vim.log.levels.ERROR)
        return
      end
      M.run_new_session(prompt, opts)
    end,
  },

  command = {
    desc = 'Run user-defined command',
    completions = function()
      local user_commands = config_file.get_user_commands()
      if not user_commands then
        return {}
      end
      local names = vim.tbl_keys(user_commands)
      table.sort(names)
      return names
    end,
    fn = function(args)
      local name = args[1]
      if not name or name == '' then
        vim.notify('Command name required', vim.log.levels.ERROR)
        return
      end
      M.run_user_command(name, vim.list_slice(args, 2))
    end,
  },

  help = {
    desc = 'Show this help message',
    fn = M.help,
  },

  mcp = {
    desc = 'Show MCP server configuration',
    fn = M.mcp,
  },

  commands_list = {
    desc = 'Show user-defined commands',
    fn = M.commands_list,
  },

  permission = {
    desc = 'Respond to permissions (accept/accept_all/deny)',
    completions = { 'accept', 'accept_all', 'deny' },
    fn = function(args)
      local subcmd = args[1]
      if subcmd == 'accept' then
        M.permission_accept()
      elseif subcmd == 'accept_all' then
        M.permission_accept_all()
      elseif subcmd == 'deny' then
        M.permission_deny()
      else
        local valid_subcmds = table.concat(M.commands.permission.completions, ', ')
        vim.notify('Invalid permission subcommand. Use: ' .. valid_subcmds, vim.log.levels.ERROR)
      end
    end,
  },

  timeline = {
    desc = 'Open timeline picker to navigate/undo/redo/fork to message',
    fn = M.timeline,
  },
}

M.slash_commands_map = {
  ['/help'] = { fn = M.help, desc = 'Show help message' },
  ['/agent'] = { fn = M.select_agent, desc = 'Select agent mode' },
  ['/agents_init'] = { fn = M.initialize, desc = 'Initialize AGENTS.md session' },
  ['/child-sessions'] = { fn = M.select_child_session, desc = 'Select child session' },
  ['/command-list'] = { fn = M.commands_list, desc = 'Show user-defined commands' },
  ['/compact'] = { fn = M.compact_session, desc = 'Compact current session' },
  ['/mcp'] = { fn = M.mcp, desc = 'Show MCP server configuration' },
  ['/models'] = { fn = M.configure_provider, desc = 'Switch provider/model' },
  ['/new'] = { fn = M.open_input_new_session, desc = 'Create new session' },
  ['/redo'] = { fn = M.redo, desc = 'Redo last action' },
  ['/sessions'] = { fn = M.select_session, desc = 'Select session' },
  ['/share'] = { fn = M.share, desc = 'Share current session' },
  ['/timeline'] = { fn = M.timeline, desc = 'Open timeline picker' },
  ['/undo'] = { fn = M.undo, desc = 'Undo last action' },
  ['/unshare'] = { fn = M.unshare, desc = 'Unshare current session' },
}

M.legacy_command_map = {
  OpencodeSwapPosition = 'swap',
  OpencodeToggleFocus = 'toggle_focus',
  OpencodeOpenInput = 'open input',
  OpencodeOpenInputNewSession = 'session new',
  OpencodeOpenOutput = 'open output',
  OpencodeCreateNewSession = 'session new',
  OpencodeClose = 'close',
  OpencodeStop = 'cancel',
  OpencodeSelectSession = 'session select',
  OpencodeSelectChildSession = 'session child',
  OpencodeTogglePane = 'toggle_pane',
  OpencodeConfigureProvider = 'models',
  OpencodeRun = 'run',
  OpencodeRunNewSession = 'run_new',
  OpencodeDiff = 'diff open',
  OpencodeDiffNext = 'diff next',
  OpencodeDiffPrev = 'diff prev',
  OpencodeDiffClose = 'diff close',
  OpencodeRevertAllLastPrompt = 'revert all prompt',
  OpencodeRevertThisLastPrompt = 'revert this prompt',
  OpencodeRevertAllSession = 'revert all session',
  OpencodeRevertThisSession = 'revert this session',
  OpencodeRevertAllToSnapshot = 'revert all',
  OpencodeRevertThisToSnapshot = 'revert this',
  OpencodeRestoreSnapshotFile = 'restore file',
  OpencodeRestoreSnapshotAll = 'restore all',
  OpencodeSetReviewBreakpoint = 'breakpoint',
  OpencodeInit = 'session agents_init',
  OpencodeHelp = 'help',
  OpencodeMCP = 'mcp',
  OpencodeAgentPlan = 'agent plan',
  OpencodeAgentBuild = 'agent build',
  OpencodeAgentSelect = 'agent select',
  OpencodeRunUserCommand = 'command',
  OpencodeCompactSession = 'session compact',
  OpencodeShareSession = 'session share',
  OpencodeUnshareSession = 'session unshare',
  OpencodeUndo = 'undo',
  OpencodeRedo = 'redo',
  OpencodePermissionAccept = 'permission accept',
  OpencodePermissionAcceptAll = 'permission accept_all',
  OpencodePermissionDeny = 'permission deny',
}

function M.route_command(opts)
  local args = vim.split(opts.args or '', '%s+', { trimempty = true })

  if #args == 0 then
    M.toggle()
    return
  end

  local subcommand = args[1]
  local subcmd_def = M.commands[subcommand]

  if subcmd_def and subcmd_def.fn then
    subcmd_def.fn(vim.list_slice(args, 2))
  else
    vim.notify('Unknown subcommand: ' .. subcommand, vim.log.levels.ERROR)
  end
end

function M.complete_command(arg_lead, cmd_line, cursor_pos)
  local parts = vim.split(cmd_line, '%s+', { trimempty = false })
  local num_parts = #parts

  if num_parts <= 2 then
    local subcommands = vim.tbl_keys(M.commands)
    table.sort(subcommands)
    return vim.tbl_filter(function(cmd)
      return vim.startswith(cmd, arg_lead)
    end, subcommands)
  end

  local subcommand = parts[2]
  local subcmd_def = M.commands[subcommand]

  if not subcmd_def then
    return {}
  end

  if num_parts <= 3 and subcmd_def.completions then
    local completions = subcmd_def.completions
    if type(completions) == 'function' then
      completions = completions() --[[@as string[] ]]
    end
    return vim.tbl_filter(function(opt)
      return vim.startswith(opt, arg_lead)
    end, completions)
  end

  if num_parts <= 4 and subcmd_def.sub_completions then
    return vim.tbl_filter(function(opt)
      return vim.startswith(opt, arg_lead)
    end, subcmd_def.sub_completions)
  end

  return {}
end

function M.setup_legacy_commands()
  local config = require('opencode.config')
  if not config.legacy_commands then
    return
  end

  for legacy_name, new_route in pairs(M.legacy_command_map) do
    vim.api.nvim_create_user_command(legacy_name, function(opts)
      vim.notify(
        string.format(':%s is deprecated. Use `:Opencode %s` instead', legacy_name, new_route),
        vim.log.levels.WARN
      )
      vim.cmd('Opencode ' .. new_route)
    end, {
      desc = 'deprecated',
      nargs = '*',
    })
  end
end

function M.get_slash_commands()
  local result = {}
  for slash_cmd, def in pairs(M.slash_commands_map) do
    table.insert(result, {
      slash_cmd = slash_cmd,
      desc = def.desc,
      fn = def.fn,
    })
  end

  local user_commands = config_file.get_user_commands()
  if user_commands then
    for name, def in pairs(user_commands) do
      table.insert(result, {
        slash_cmd = '/' .. name,
        desc = def.description or 'User command',
        fn = function(...)
          M.run_user_command(name, ...)
        end,
        args = config_file.command_takes_arguments(def),
      })
    end
  end

  return result
end

function M.setup()
  vim.api.nvim_create_user_command('Opencode', M.route_command, {
    desc = 'Opencode.nvim main command with nested subcommands',
    nargs = '*',
    complete = M.complete_command,
  })

  M.setup_legacy_commands()
end

return M
