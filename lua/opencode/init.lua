local M = {}
local config = require('opencode.config')
local keymap = require('opencode.keymap')
local api = require('opencode.api')
local config_file = require('opencode.config_file')
local context = require('opencode.context')

function M.setup(opts)
  config.setup(opts)
  config_file.setup()
  api.setup()
  keymap.setup(config.get('keymap'))

  require('opencode.ui.completion').setup()

  vim.schedule(function()
    local ui_conf = config.get('ui')
    if ui_conf.display_context_size or ui_conf.display_cost then
      require('opencode.models').setup()
    end
    require('opencode.ui.context_bar').setup()
    context.setup()
  end)
end

return M
