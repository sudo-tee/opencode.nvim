local M = {}
local config = require('opencode.config')
local keymap = require('opencode.keymap')
local api = require('opencode.api')
local config_file = require('opencode.config_file')

function M.setup(opts)
  config.setup(opts)
  config_file.setup()
  api.setup()
  keymap.setup(config.get('keymap'))
end

return M
