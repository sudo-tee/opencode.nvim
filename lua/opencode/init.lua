local M = {}
local config = require('opencode.config')
local keymap = require('opencode.keymap')
local api = require('opencode.api')
local config_file = require('opencode.config_file')

function M.setup(opts)
  vim.schedule(function()
    require('opencode.core').setup()
    config.setup(opts)
    api.setup()
    keymap.setup(config.get('keymap'))

    require('opencode.ui.completion').setup()
    require('opencode.event_manager').setup()
  end)
end

return M
