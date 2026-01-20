local M = {}
local base_picker = require('opencode.ui.base_picker')
local state = require('opencode.state')
local config_file = require('opencode.config_file')
local model_state = require('opencode.model_state')
local util = require('opencode.util')

---Get variants for the current model
---@return table[] variants Array of variant items
local function get_current_model_variants()
  if not state.current_model then
    return {}
  end

  local provider, model = state.current_model:match('^(.-)/(.+)$')
  if not provider or not model then
    return {}
  end

  local model_info = config_file.get_model_info(provider, model)
  if not model_info or not model_info.variants then
    return {}
  end

  local variants = {}
  for variant_name, variant_config in pairs(model_info.variants) do
    table.insert(variants, {
      name = variant_name,
      config = variant_config,
    })
  end

  util.sort_by_priority(variants, function(item)
    return item.name
  end, { low = 1, medium = 2, high = 3 })

  return variants
end

---Show variant picker
---@param callback fun(selection: table?) Callback when variant is selected
function M.select(callback)
  local variants = get_current_model_variants()

  if #variants == 0 then
    vim.notify('Current model does not support variants', vim.log.levels.WARN)
    if callback then
      callback(nil)
    end
    return
  end

  -- Get saved variant from model state if no current variant is set
  if not state.current_variant and state.current_model then
    local provider, model = state.current_model:match('^(.-)/(.+)$')
    if provider and model then
      local saved_variant = model_state.get_variant(provider, model)
      if saved_variant then
        state.current_variant = saved_variant
      end
    end
  end

  base_picker.pick({
    title = 'Select variant',
    items = variants,
    format_fn = function(item, width)
      local item_width = width or vim.api.nvim_win_get_width(0)
      local is_current = state.current_variant == item.name
      local current_indicator = is_current and '*' or '  '

      local name_width = item_width - vim.api.nvim_strwidth(current_indicator)

      local picker_item = base_picker.create_picker_item({
        {
          text = current_indicator,
          highlight = is_current and 'OpencodeContextSwitchOn' or 'OpencodeHint',
        },
        {
          text = base_picker.align(item.name, name_width, { truncate = true }),
          highlight = is_current and 'OpencodeContextSwitchOn' or nil,
        },
      })

      return picker_item
    end,
    actions = {},
    callback = function(selection)
      if selection and state.current_model then
        state.current_variant = selection.name

        -- Save variant to model state
        local provider, model = state.current_model:match('^(.-)/(.+)$')
        if provider and model then
          model_state.set_variant(provider, model, selection.name)
        end
      end
      if callback then
        callback(selection)
      end
    end,
  })
end

return M
