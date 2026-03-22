local Promise = require('opencode.promise')
local config_file = require('opencode.config_file')
---@type OpencodeState
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local window_handler = require('opencode.commands.handlers.window')
local nvim = vim.api

local M = {
  actions = {},
}

---@return table<string, OpencodeUICommand>
local function get_command_definitions()
  return require('opencode.commands').get_commands()
end

---@param lines string[]
---@param show_welcome? boolean
---@return string[]
function M.actions.with_header(lines, show_welcome)
  show_welcome = show_welcome or false
  state.ui.set_display_route('/header')

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

function M.actions.help()
  state.ui.set_display_route('/help')
  window_handler.actions.open_input()
  local msg = M.actions.with_header({
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

  if not state.ui.is_visible() or not state.windows.output_win then
    return
  end

  local max_desc_length = math.min(90, nvim.nvim_win_get_width(state.windows.output_win) - 35)

  local command_defs = get_command_definitions()
  local sorted_commands = vim.tbl_keys(command_defs)
  table.sort(sorted_commands)

  for _, name in ipairs(sorted_commands) do
    local def = command_defs[name]
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

M.actions.commands_list = Promise.async(function()
  local commands = config_file.get_user_commands():await()
  if not commands then
    vim.notify('No user commands found. Please check your opencode config file.', vim.log.levels.WARN)
    return
  end

  state.ui.set_display_route('/commands')
  window_handler.actions.open_input()

  local msg = M.actions.with_header({
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
end)

M.actions.mcp = Promise.async(function()
  local mcp_picker = require('opencode.ui.mcp_picker')
  mcp_picker.pick()
end)

M.command_defs = {
  help = {
    desc = 'Show this help message',
    execute = M.actions.help,
  },
  commands_list = {
    desc = 'Show user-defined commands',
    execute = M.actions.commands_list,
  },
  mcp = {
    desc = 'Show MCP server configuration',
    execute = M.actions.mcp,
  },
}

return M
