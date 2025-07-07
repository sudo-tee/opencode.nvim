local core = require('opencode.core')
local api = require('opencode.api')

local M = {}

M.default_handlers = {
  ['/help'] = {
    desc = 'Show this help message',
    fn = function()
      local state = require('opencode.state')
      state.slash_command = '/help'

      local commands = M.get_handlers()

      local msg = {
        '## Opencode.nvim Help',
        '',
        '  █▀▀█ █▀▀█ █▀▀ █▀▀▄ █▀▀ █▀▀█ █▀▀▄ █▀▀',
        '  █░░█ █░░█ █▀▀ █░░█ █░░ █░░█ █░░█ █▀▀',
        '  ▀▀▀▀ █▀▀▀ ▀▀▀ ▀  ▀ ▀▀▀ ▀▀▀▀ ▀▀▀  ▀▀▀',
        '',
        'Welcome to Opencode.nvim! This plugin allows you to interact with AI models directly from Neovim.',
        '',
        'Type your prompt or use `/` for custom actions.',
        '',
        '### Slash Commands',
        '',
        '| Command   | Description                                    |',
        '|-----------|------------------------------------------------|',
      }
      for cmd, def in pairs(commands) do
        table.insert(msg, string.format('| %-10s | %-46s |', cmd, def.desc))
      end

      require('opencode.ui.ui').render_lines(msg)
    end,
  },
  ['/init'] = {
    desc = 'Initialize/Update AGENTS.md file',
    fn = function()
      api.initialize()
    end,
  },
  ['/session'] = {
    desc = 'Select a session',
    fn = function()
      core.select_session()
    end,
  },
  ['/stop'] = {
    desc = 'Stop the current opencode job',
    fn = function()
      core.stop()
    end,
  },
  ['/provider'] = {
    desc = 'Configure the provider/model',
    fn = function()
      core.configure_provider()
    end,
  },
  ['/new'] = {
    desc = 'Start a new opencode session',
    fn = function()
      core.open({
        new_session = true,
      })
    end,
  },
}

function M.get_handlers()
  local config = require('opencode.config').get()
  local custom = config.custom_commands or {}
  return vim.tbl_deep_extend('force', M.default_handlers, custom)
end

function M.get_handlers_compgetion()
  local handlers = M.get_handlers()
  local items = {}
  local max_len = 0
  for cmd, _ in pairs(handlers) do
    max_len = math.max(max_len, #cmd)
  end
  for cmd, def in pairs(handlers) do
    if def.desc then
      local padded_cmd = cmd .. string.rep(' ', max_len - #cmd)
      table.insert(items, {
        word = cmd:sub(2), -- remove leading slash
        abbr = padded_cmd .. ' │ ' .. def.desc,
        menu = '',
      })
    else
      table.insert(items, {
        word = cmd,
        menu = '',
      })
    end
  end
  vim.fn.complete(vim.fn.col('.'), items)
end

return M
