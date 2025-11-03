local M = {}

local completion_sources = {}

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

  local setup_success = false

  local engine = M.get_completion_engine()

  if engine == 'nvim-cmp' then
    require('opencode.ui.completion.engines.nvim_cmp').setup(completion_sources)
    setup_success = true
  elseif engine == 'blink' then
    require('opencode.ui.completion.engines.blink_cmp').setup(completion_sources)
    setup_success = true
  elseif engine == 'vim_complete' then
    require('opencode.ui.completion.engines.vim_complete').setup(completion_sources)
    setup_success = true
  end

  if not setup_success then
    vim.notify('Opencode: No completion engine available', vim.log.levels.WARN)
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
    local engine = M.get_completion_engine()

    if engine == 'vim_complete' then
      require('opencode.ui.completion.engines.vim_complete').trigger(trigger_char)
    elseif engine == 'blink' then
      vim.api.nvim_feedkeys(trigger_char, 'in', true)
      require('blink.cmp').show({ providers = { 'opencode_mentions' } })
    else
      vim.api.nvim_feedkeys(trigger_char, 'in', true)
    end
  end
end

return M
