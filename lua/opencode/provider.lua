local M = {}

function M._get_models()
  local config_file = require('opencode.config_file')
  local response = config_file.get_opencode_providers():wait()

  if not response then
    return {}
  end

  local models = {}
  for _, provider in ipairs(response.providers) do
    for _, model in pairs(provider.models) do
      table.insert(models, {
        provider = provider.id,
        model = model.id,
        display = provider.name .. ': ' .. model.name,
      })
    end
  end
  return models
end

function M.select(cb)
  local models = M._get_models()

  local picker = require('opencode.ui.picker')
  picker.select(models, {
    prompt = 'Select model:',
    format_item = function(item)
      return item.display
    end,
  }, function(selection)
    cb(selection)
  end)
end

return M
