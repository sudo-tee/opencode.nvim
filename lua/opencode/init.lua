local M = {}

local setup_done = false
local state

local session_runtime = require('opencode.services.session_runtime')
local slash_registry = require('opencode.services.slash_registry')

M.register_slash_command = slash_registry.register
M.unregister_slash_command = slash_registry.unregister

---Register a recipe-owned completion source.
---@param source CompletionSource
function M.register_completion_source(source)
  return require('opencode.ui.completion').register_source(source)
end

---Unregister a recipe-owned completion source.
---@param name string
---@return boolean
function M.unregister_completion_source(name)
  return require('opencode.ui.completion').unregister_source(name)
end

---Register a recipe-owned tool formatter. Replacing a built-in formatter
---requires `opts.replace = true`.
---@param name string
---@param formatter ToolFormatter
---@param opts? { replace?: boolean }
function M.register_tool_formatter(name, formatter, opts)
  return require('opencode.ui.formatter.tool_registry').register(name, formatter, opts)
end

---Unregister a recipe-owned tool formatter. An active built-in override is
---removed and the built-in formatter is restored.
---@param name string
---@return boolean
function M.unregister_tool_formatter(name)
  return require('opencode.ui.formatter.tool_registry').unregister(name)
end

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
  require('opencode.services.session_tab_persistence').setup()
  session_runtime.setup_subscriptions()
  state.store.subscribe('opencode_server', on_opencode_server)
  state.store.subscribe('user_message_count', session_runtime._on_user_message_count_change)
  state.store.subscribe('pending_permissions', session_runtime._on_current_permission_change)

  vim.schedule(function()
    session_runtime.opencode_ok()
  end)
  require('opencode.ui.permission_window')
  require('opencode.ui.question_window')
  require('opencode.commands').setup()
  local slash = require('opencode.commands.slash')
  require('opencode.ui.completion').setup({ execute_slash_command = slash.execute_builtin })
  require('opencode.keymap').setup(config.keymap)
  require('opencode.ui.contextual_actions').setup()
  require('opencode.ui.autocmds').setup_subscriptions()
  require('opencode.ui.session_tab_notifications').setup()
  require('opencode.ui.program_status').setup()
  require('opencode.context').setup()
  require('opencode.ui.context_bar').setup()
end

return M
