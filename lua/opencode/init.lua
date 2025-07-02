local M = {}
local config = require("opencode.config")
local keymap = require("opencode.keymap")
local api = require("opencode.api")

function M.setup(opts)
  config.setup(opts)
  api.setup()
  keymap.setup(config.get("keymap"))
end

return M
