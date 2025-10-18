local M = {}

function M.setup(opts)
  vim.schedule(function()
    -- Have to setup config first, especially before state as
    -- it initializes at least one value (current_mode) from config.
    -- If state is require'd first then it will not get what may
    -- be set by the user
    local config = require('opencode.config')
    config.setup(opts)

    require('opencode.core').setup()
    require('opencode.api').setup()
    require('opencode.keymap').setup(config.keymap)
    require('opencode.ui.completion').setup()
    require('opencode.event_manager').setup()
  end)
end

return M
