local M = {}

local setup_done = false
local state

local session_runtime = require('opencode.services.session_runtime')

local function on_opencode_server()
  require('opencode.ui.permission_window').clear_all()
end

function M.setup(opts)
  if setup_done then
    return
  end
  setup_done = true

  -- Have to setup config first, especially before state as
  -- it initializes at least one value (current_mode) from config.
  -- If state is require'd first then it will not get what may
  -- be set by the user
  local config = require('opencode.config')
  config.setup(opts)

  require('opencode.ui.highlight').setup()

  state = require('opencode.state')
  state.session_tabs.setup()
  state.store.subscribe('opencode_server', on_opencode_server)
  state.store.subscribe('user_message_count', session_runtime._on_user_message_count_change)
  state.store.subscribe('pending_permissions', session_runtime._on_current_permission_change)

  vim.schedule(function()
    session_runtime.opencode_ok()
  end)
  local OpencodeApiClient = require('opencode.api_client')
  state.jobs.set_api_client(OpencodeApiClient.create())

  require('opencode.ui.permission_window')
  require('opencode.ui.question_window')
  require('opencode.commands').setup()
  require('opencode.ui.completion').setup()
  require('opencode.keymap').setup(config.keymap)
  require('opencode.event_manager').setup()
  session_runtime.setup()
  require('opencode.ui.session_tab_notifications').setup()
  require('opencode.context').setup()
  require('opencode.ui.context_bar').setup()
end

return M
