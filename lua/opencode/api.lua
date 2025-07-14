local core = require('opencode.core')
local util = require('opencode.util')

local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local review = require('opencode.review')
local history = require('opencode.history')

local M = {}

-- Core API functions

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

function M.toggle()
  if state.windows == nil then
    local focus = state.last_focused_opencode_window or 'input'
    core.open({ new_session = false, focus = focus })
  else
    M.close()
  end
end

function M.toggle_focus()
  if not ui.is_opencode_focused() then
    local focus = state.last_focused_opencode_window or 'input'
    core.open({ new_session = false, focus = focus })
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

function M.toggle_fullscreen()
  if not state.windows then
    core.open({ new_session = false, focus = 'output' })
  end

  ui.toggle_fullscreen()
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

function M.diff_open()
  review.review()
end

function M.diff_next()
  review.next_diff()
end

function M.diff_prev()
  review.prev_diff()
end

function M.diff_close()
  review.close_diff()
end

function M.diff_revert_all()
  review.revert_all()
end

function M.diff_revert_this()
  review.revert_current()
end

function M.set_review_breakpoint()
  review.set_breakpoint()
end

function M.prev_history()
  local prev_prompt = history.prev()
  if prev_prompt then
    ui.write_to_input(prev_prompt)
  end
end

function M.next_history()
  local next_prompt = history.next()
  if next_prompt then
    ui.write_to_input(next_prompt)
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
  local config_path = require('opencode.info').config_file
  if vim.fn.filereadable(config_path) == 1 then
    if ui.is_opencode_focused() then
      vim.api.nvim_set_current_win(state.last_code_win_before_opencode)
    end

    vim.cmd('edit ' .. config_path)
  else
    ui.notify('Configuration file not found: ' .. config_path, 'error')
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
  local modes = require('opencode.info').get_opencode_modes()
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
  local modes = require('opencode.info').get_opencode_modes()

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

  ui.render_lines(msg)
end

function M.mcp()
  local info = require('opencode.info')
  local mcp = info.get_mcp_servers()
  if not mcp then
    ui.notify('No MCP configuration found. Please check your opencode config file.', 'warn')
    return
  end

  state.display_route = '/mcp'

  local msg = M.with_header({
    '### Available MCP servers',
    '',
    '| Name   | type | cmd|',
    '|--------|------|----|',
  })

  for name, def in pairs(mcp) do
    table.insert(
      msg,
      string.format(
        '| %s %-10s | %s |%s|',
        def.enabled and '🟢' or '⚫',
        name,
        def.type,
        table.concat(def.command, ' ')
      )
    )
  end

  ui.render_lines(msg)
end

-- Command definitions that call the API functions
M.commands = {
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

  toggle_fullscreen = {
    name = 'OpencodeToggleFullscreen',
    desc = 'Toggle between normal and fullscreen mode',
    fn = function()
      M.toggle_fullscreen()
    end,
  },

  select_session = {
    name = 'OpencodeSelectSession',
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
  },

  run_new_session = {
    name = 'OpencodeRunNewSession',
    desc = 'Run opencode with a prompt (new session)',
    fn = function(opts)
      M.run_new_session(opts.args)
    end,
  },

  -- Updated diff command names
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

  diff_revert_all = {
    name = 'OpencodeRevertAll',
    desc = 'Revert all file changes since the last opencode prompt',
    fn = function()
      M.diff_revert_all()
    end,
  },

  diff_revert_this = {
    name = 'OpencodeRevertThis',
    desc = 'Revert current file changes since the last opencode prompt',
    fn = function()
      M.diff_revert_this()
    end,
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
    desc = 'Initialize/Update AGENTS.md file',
    fn = function()
      M.initialize()
    end,
  },
  help = {
    name = 'OpencodeHelp',
    desc = 'Display help message',
    fn = function()
      M.open_input()
      M.help()
    end,
  },
  mcp = {
    name = 'OpencodeMCP',
    desc = 'Display list od mcp servers',
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
    desc = 'Select opencode mode',
    fn = function()
      M.select_mode()
    end,
  },
}

function M.setup()
  -- Register commands without arguments
  for key, cmd in pairs(M.commands) do
    if key ~= 'run' and key ~= 'run_new_session' then
      vim.api.nvim_create_user_command(cmd.name, cmd.fn, {
        desc = cmd.desc,
      })
    end
  end

  -- Register commands with arguments
  vim.api.nvim_create_user_command(M.commands.run.name, M.commands.run.fn, {
    desc = M.commands.run.desc,
    nargs = '+',
  })

  vim.api.nvim_create_user_command(M.commands.run_new_session.name, M.commands.run_new_session.fn, {
    desc = M.commands.run_new_session.desc,
    nargs = '+',
  })
end

return M
