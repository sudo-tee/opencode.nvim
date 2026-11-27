local M = {}

local setup_done = false
---@type OpencodeState?
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

---Register a recipe-owned formatter for file attachments in user messages.
---Formatters run in registration order; the first one that writes lines wins.
---@param name string
---@param formatter OpencodeAttachmentFormatter
function M.register_attachment_formatter(name, formatter)
  return require('opencode.ui.formatter.attachment_registry').register(name, formatter)
end

---@param name string
---@return boolean
function M.unregister_attachment_formatter(name)
  return require('opencode.ui.formatter.attachment_registry').unregister(name)
end

---Buffer lines a rendered part occupies in the output, e.g. an attachment's
---`part_id`. Returns nil when the part is not rendered.
---@param part_id string
---@return OpencodeRenderedPartLines?
function M.get_rendered_part(part_id)
  return require('opencode.ui.renderer').get_part_lines(part_id)
end

---Register a recipe-owned context provider. Its items are shown in the
---context bar and `#` picker and sent as text/plain attachments.
---@param provider OpencodeContextProvider
function M.register_context_provider(provider)
  return require('opencode.context.providers').register(provider)
end

---@param name string
---@return boolean
function M.unregister_context_provider(name)
  return require('opencode.context.providers').unregister(name)
end

---Redraw context surfaces after a provider's items changed.
function M.refresh_context()
  return require('opencode.context.providers').refresh()
end

---Insert `@<item.name>` into the prompt so a `reference` provider sends the item.
---@param item OpencodeContextProviderItem
function M.insert_context_reference(item)
  local providers = require('opencode.context.providers')
  require('opencode.ui.input_window').insert_mention(providers.reference(item))
  providers.refresh()
end

---Whether the current window is the main OpenCode prompt input.
---@return boolean
function M.is_input_window()
  local windows = state and state.windows
  return windows ~= nil
    and windows.input_win == vim.api.nvim_get_current_win()
    and windows.input_buf == vim.api.nvim_get_current_buf()
end

local function on_opencode_server()
  require('opencode.ui.permission_window').clear_all()
end

---@param opts? OpencodeConfig
function M.setup(opts)
  if setup_done then
    return
  end
  -- Resolved before marking setup done so a bad recipe name can be fixed and setup retried.
  local recipes = require('opencode.recipes')
  local merged, loaded = recipes.resolve(opts)
  setup_done = true

  -- Have to setup config first, especially before state as
  -- it initializes at least one value (current_mode) from config.
  -- If state is require'd first then it will not get what may
  -- be set by the user
  local config = require('opencode.config')
  config.setup(merged)

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

  recipes.run(loaded, M)
end

return M
