local M = {}

function M._get_models()
  local config_file = require('opencode.config_file')
  local response = config_file.get_opencode_providers():wait()

  if not response then
    return {}
  end

  local config = require('opencode.config')
  local icons = require('opencode.ui.icons')
  local preferred_model = config.values.preferred_model
  local preferred_icon = icons.get('preferred')

  local models = {}
  for _, provider in ipairs(response.providers) do
    for _, model in pairs(provider.models) do
      local model_id = provider.id .. '/' .. model.id
      local is_preferred = preferred_model and model_id == preferred_model

      table.insert(models, {
        provider = provider.id,
        model = model.id,
        display = (is_preferred and preferred_icon or '') .. provider.name .. ': ' .. model.name,
        is_preferred = is_preferred,
      })
    end
  end

  -- Sort models: preferred first, then alphabetically
  table.sort(models, function(a, b)
    if a.is_preferred and not b.is_preferred then
      return true
    elseif not a.is_preferred and b.is_preferred then
      return false
    else
      return a.display < b.display
    end
  end)

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
