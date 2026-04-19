local M = {}

local setup_done = false
local state

local session_runtime = require('opencode.services.session_runtime')

local function on_opencode_server()
  require('opencode.ui.permission_window').clear_all()
end

local function on_current_model_change(_key, new_val, old_val)
  if new_val ~= old_val then
    state.model.clear_variant()

    if new_val then
      local provider, model = new_val:match('^(.-)/(.+)$')
      if provider and model then
        local model_state = require('opencode.model_state')
        local saved_variant = model_state.get_variant(provider, model)
        if saved_variant then
          state.model.set_variant(saved_variant)
        end
      end
    end
  end
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
  state.store.subscribe('opencode_server', on_opencode_server)
  state.store.subscribe('user_message_count', session_runtime._on_user_message_count_change)
  state.store.subscribe('pending_permissions', session_runtime._on_current_permission_change)
  state.store.subscribe('current_model', on_current_model_change)

  vim.schedule(function()
    session_runtime.opencode_ok()
  end)
  local OpencodeApiClient = require('opencode.api_client')
  state.jobs.set_api_client(OpencodeApiClient.create())

  require('opencode.commands').setup()
  require('opencode.ui.completion').setup()
  require('opencode.keymap').setup(config.keymap)
  require('opencode.event_manager').setup()
  require('opencode.context').setup()
  require('opencode.ui.context_bar').setup()
  require('opencode.ui.reference_picker').setup()
end

return M
