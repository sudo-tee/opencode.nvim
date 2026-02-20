local M = {}

local completion_sources = {}
M._current_engine = nil
M._pending = {}

-- Engine configuration mapping
local ENGINE_CONFIG = {
  ['nvim-cmp'] = {
    module = 'opencode.ui.completion.engines.nvim_cmp',
    constructor = 'new',
  },
  ['blink'] = {
    module = 'opencode.ui.completion.engines.blink_cmp',
    constructor = 'create', -- Special case for blink
  },
  ['vim_complete'] = {
    module = 'opencode.ui.completion.engines.vim_complete',
    constructor = 'new',
  },
}

---Load and create an engine instance
---@param engine_name string
---@return table|nil engine
local function load_engine(engine_name)
  local config = ENGINE_CONFIG[engine_name]
  if not config then
    vim.notify('Unknown completion engine: ' .. tostring(engine_name), vim.log.levels.WARN)
    return nil
  end

  local ok, EngineClass = pcall(require, config.module)
  if not ok then
    vim.notify('Failed to load ' .. engine_name .. ' engine: ' .. tostring(EngineClass), vim.log.levels.ERROR)
    return nil
  end

  local constructor = EngineClass[config.constructor]
  if not constructor then
    vim.notify('Engine ' .. engine_name .. ' missing ' .. config.constructor .. ' method', vim.log.levels.ERROR)
    return nil
  end

  return constructor()
end

function M.setup()
  local files_source = require('opencode.ui.completion.files')
  local subagents_source = require('opencode.ui.completion.subagents')
  local commands_source = require('opencode.ui.completion.commands')
  local context_source = require('opencode.ui.completion.context')

  M.register_source(files_source.get_source())
  M.register_source(subagents_source.get_source())
  M.register_source(commands_source.get_source())
  M.register_source(context_source.get_source())

  table.sort(completion_sources, function(a, b)
    return (a.priority or 0) > (b.priority or 0)
  end)

  local engine_name = M.get_completion_engine()
  local engine = load_engine(engine_name)
  local setup_success = false

  -- if engine and engine.setup then
  --   setup_success = engine:setup(completion_sources)
  -- end
  --
  -- if setup_success then
  --   M._current_engine = engine
  -- else
  --   M._current_engine = nil
  --   vim.notify(
  --     'Opencode: No completion engine available (engine: ' .. tostring(engine_name) .. ')',
  --     vim.log.levels.WARN
  --   )
  -- end
end

function M.on_insert_enter()
  M._last_line = vim.api.nvim_get_current_line()
  M._last_col = vim.api.nvim_win_get_cursor(0)[2]
end

function M.on_text_changed()
  if not next(M._pending) then
    return
  end

  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- detect inserted text
  local inserted = line:sub(M._last_col + 1, col)

  if M._pending[inserted] then
    local item = M._pending[inserted]

    M._pending = {}

    -- Notify the LSP server about the completed item
    local ok, opencode_ls = pcall(require, 'opencode.lsp.opencode_ls')
    if ok and opencode_ls.on_completion_done then
      opencode_ls.on_completion_done(item)
    end
  end

  M._last_line = line
  M._last_col = col
end

function M.store_completion_items(items)
  M._pending = {}
  M._last_line = vim.api.nvim_get_current_line()
  M._last_col = vim.api.nvim_win_get_cursor(0)[2]

  for _, item in ipairs(items or {}) do
    local word = item.insertText or item.label
    ---strip the trigger character from the start of the word if it exists, this is needed for the slash commands and mentions completion to work properly
    local config = require('opencode.config')
    local triggers = {
      config.get_key_for_function('input_window', 'mention'),
      config.get_key_for_function('input_window', 'slash_commands'),
      config.get_key_for_function('input_window', 'context_items'),
    }
    for _, t in ipairs(triggers) do
      if t and word:sub(1, #t) == t then
        word = word:sub(#t + 1)
        break
      end
    end

    if word then
      M._pending[word] = item
    end
  end
end

---Register a completion source
---@param source CompletionSource
function M.register_source(source)
  table.insert(completion_sources, source)
end

---@return CompletionSource[]
function M.get_sources()
  return completion_sources
end

function M.get_source_by_name(name)
  for _, source in ipairs(completion_sources) do
    if source.name == name then
      return source
    end
  end
  return nil
end

---Call the on_complete method for a completion item
---@param item CompletionItem
function M.on_complete(item)
  if not item.source_name then
    return
  end

  -- Find the source that provided this item
  for _, source in ipairs(completion_sources) do
    if source.name == item.source_name and source.on_complete then
      source.on_complete(item)
      break
    end
  end
end

function M.get_completion_engine()
  local config = require('opencode.config')
  local engine = config.preferred_completion
  if not engine then
    local ok_cmp = pcall(require, 'cmp')
    local ok_blink = pcall(require, 'blink.cmp')
    if ok_blink then
      engine = 'blink'
    elseif ok_cmp then
      engine = 'nvim-cmp'
    else
      engine = 'vim_complete'
    end
  end
  return engine
end

function M.trigger_completion(trigger_char)
  return function()
    if M._current_engine and M._current_engine.trigger then
      M._current_engine:trigger(trigger_char)
    end
  end
end

function M.hide_completion()
  if M._current_engine and M._current_engine.hide then
    M._current_engine:hide()
  end
end

function M.is_visible()
  if M._current_engine and M._current_engine.is_visible then
    return M._current_engine:is_visible()
  end
  return false
end

return M
