local M = {}

function M._get_models()
  local result = vim.system({ 'opencode', 'models' }):wait()
  if result.code ~= 0 then
    vim.notify('Failed to get providers: ' .. result.stderr, vim.log.levels.ERROR)
    return {}
  end

  local models = {}
  for line in result.stdout:gmatch('[^\n]+') do
    local provider, model = line:match('^(%S+)/(%S+)$')
    if provider and model then
      table.insert(models, {
        provider = provider,
        model = model,
        display = provider .. ': ' .. model,
      })
    end
  end
  return models
end

function M.select(cb)
  local models = M._get_models()

  vim.ui.select(models, {
    prompt = 'Select model:',
    format_item = function(item)
      return item.display
    end,
  }, function(selection)
    cb(selection)
  end)
end

return M
