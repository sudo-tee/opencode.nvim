local M = {}

function M.select(cb)
  local config = require("opencode.config")

  -- Create a flat list of all provider/model combinations
  local model_options = {}

  for provider, models in pairs(config.get("providers")) do
    for _, model in ipairs(models) do
      table.insert(model_options, {
        provider = provider,
        model = model,
        display = provider .. ": " .. model
      })
    end
  end

  if #model_options == 0 then
    vim.notify("No models configured in providers", vim.log.levels.ERROR)
    return
  end

  vim.ui.select(model_options, {
    prompt = "Select model:",
    format_item = function(item)
      return item.display
    end
  }, function(selection)
    cb(selection)
  end)
end

return M
