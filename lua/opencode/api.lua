local core = require('opencode.core')
local util = require('opencode.util')
local session = require('opencode.session')
local input_window = require('opencode.ui.input_window')

local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local git_review = require('opencode.git_review')
local history = require('opencode.history')

local M = {}

function M.swap_position()
  require('opencode.ui.ui').swap_position()
end

function M.open_input()
  core.open({ new_session = false, focus = 'input' })
  vim.cmd('startinsert')
end

function M.open_input_new_session()
  core.open({ new_session = true, focus = 'input' })
  vim.cmd('startinsert')
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

    core.open({ new_session = new_session == true, focus = focus })
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

function M.run(prompt)
  core.run(prompt, {
    ensure_ui = true,
    new_session = false,
    focus = 'output',
  })
end

function M.run_new_session(prompt)
  core.run(prompt, {
    ensure_ui = true,
    new_session = true,
    focus = 'output',
  })
end

function M.select_session()
  core.select_session()
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

  git_review.review(from_snapshot_id, to_snapshot_id)
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
---@param to_snapshot_id? string
function M.diff_revert_all(from_snapshot_id, to_snapshot_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.revert_all(from_snapshot_id, to_snapshot_id)
end
---@param from_snapshot_id? string
---@param to_snapshot_id? string
function M.diff_revert_selected_file(from_snapshot_id, to_snapshot_id)
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  git_review.revert_selected_file(from_snapshot_id, to_snapshot_id)
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
  end
end

function M.next_history()
  local next_prompt = history.next()
  if next_prompt then
    input_window.set_content(next_prompt)
  end
end

function M.initialize()
  local script_path = debug.getinfo(1, 'S').source:sub(2)
  local script_dir = vim.fn.fnamemodify(script_path, ':p:h')
  local p = vim.fn.readfile(script_dir .. '/prompts/initialize.txt')
  core.run(table.concat(p, '\n'), {
    new_session = true,
  })
end

function M.open_configuration_file()
  local config_path = require('opencode.config_file').config_file
  if vim.fn.filereadable(config_path) == 1 then
    if ui.is_opencode_focused() then
      vim.api.nvim_set_current_win(state.last_code_win_before_opencode)
    end

    vim.cmd('edit ' .. config_path)
  else
    vim.notify('Configuration file not found: ' .. config_path, 'error')
  end
end

function M.mode_plan()
  state.current_mode = 'plan'
  require('opencode.ui.topbar').render()
end

function M.mode_build()
  state.current_mode = 'build'
  require('opencode.ui.topbar').render()
end

function M.select_mode()
  local modes = require('opencode.config_file').get_opencode_modes()
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

function M.switch_to_next_mode()
  local modes = require('opencode.config_file').get_opencode_modes()

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
        def.enabled and '🟢' or '⚫',
        name,
        def.type,
        table.concat(def.command, ' ')
      )
    )
  end

  table.insert(msg, '')
  ui.render_lines(msg)
end

-- Command definitions that call the API functions
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
      M.run(opts.args)
    end,
    args = true,
  },

  run_new_session = {
    name = 'OpencodeRunNewSession',
    desc = 'Run opencode with a prompt (new session)',
    fn = function(opts)
      M.run_new_session(opts.args)
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
      M.open_input()
      M.help()
    end,
  },
  mcp = {
    name = 'OpencodeMCP',
    slash_cmd = '/mcp',
    desc = 'Display list of mcp servers',
    fn = function()
      M.open_input()
      M.mcp()
    end,
  },
  open_configuration_file = {
    name = 'OpencodeConfigFile',
    desc = 'Open opencode configuration file',
    fn = function()
      M.open_configuration_file()
    end,
  },

  opencode_mode_plan = {
    name = 'OpencodeModePlan',
    desc = 'Set opencode mode to `plan`. (Tool calling disabled. No editor context besides selections)',
    fn = function()
      M.mode_plan()
    end,
  },

  opencode_mode_build = {
    name = 'OpencodeModeBuild',
    desc = 'Set opencode mode to `build`. (Default mode with full agent capabilities)',
    fn = function()
      M.mode_build()
    end,
  },
  open_code_select_mode = {
    name = 'OpencodeModeSelect',
    slash_cmd = '/mode',
    desc = 'Select opencode mode',
    fn = function()
      M.select_mode()
    end,
  },
}

function M.get_slash_commands()
  local commands = vim.tbl_filter(function(cmd)
    return cmd.slash_cmd and cmd.slash_cmd ~= ''
  end, M.commands)
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
