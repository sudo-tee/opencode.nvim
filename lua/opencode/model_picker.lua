local config = require('opencode.config')
local model_state = require('opencode.model_state')
local M = {}

function M._get_models()
  local config_file = require('opencode.config_file')
  local response = config_file.get_opencode_providers():wait()

  if not response then
    return {}
  end

  local icons = require('opencode.ui.icons')
  local preferred_icon = icons.get('preferred')
  local last_used_icon = icons.get('last_used')

  local state = model_state.load()

  local models = {}
  for _, provider in ipairs(response.providers) do
    for _, model in pairs(provider.models) do
      local provider_id = provider.id
      local model_id = model.id
      local fav_idx = model_state.get_model_index(provider_id, model_id, state.favorite)
      local recent_idx = model_state.get_model_index(provider_id, model_id, state.recent)

      local icon = nil
      if fav_idx then
        icon = preferred_icon
      elseif recent_idx then
        icon = last_used_icon
      end

      table.insert(models, {
        provider = provider_id,
        provider_name = provider.name,
        model = model_id,
        model_name = model.name,
        icon = icon,
        favorite_index = fav_idx or 999, -- High number for non-favorite items
        recent_index = recent_idx or 999, -- High number for non-recent items
      })
    end
  end

  table.sort(models, function(a, b)
    if a.favorite_index < 999 and b.favorite_index < 999 then
      return a.favorite_index < b.favorite_index
    end

    if a.favorite_index < 999 and b.favorite_index >= 999 then
      return true
    end

    if a.favorite_index >= 999 and b.favorite_index < 999 then
      return false
    end

    if a.recent_index ~= b.recent_index then
      return a.recent_index < b.recent_index
    end

    if a.provider_name ~= b.provider_name then
      return a.provider_name < b.provider_name
    end

    return a.model_name < b.model_name
  end)

  return models
end

function M.select(cb)
  local models = M._get_models()
  local base_picker = require('opencode.ui.base_picker')

  local max_provider_width, max_icon_width = 0, 0
  for _, m in ipairs(models) do
    max_provider_width = math.max(max_provider_width, vim.api.nvim_strwidth(m.provider_name))
    if m.icon and m.icon ~= '' then
      max_icon_width = math.max(max_icon_width, vim.api.nvim_strwidth(m.icon))
    end
  end
  local icon_width = max_icon_width > 0 and max_icon_width + 1 or 0
  local provider_icon_width = max_provider_width + icon_width

  base_picker.pick({
    title = 'Select model',
    items = models,
    format_fn = function(item, width)
      local icon = item.icon or ''
      local item_width = width or vim.api.nvim_win_get_width(0)
      local model_width = item_width - provider_icon_width

      local picker_item = {
        parts = {
          base_picker.align(item.model_name, model_width, { truncate = true }),
          base_picker.align(item.provider_name, max_provider_width, { align = 'left' })
            .. (icon_width > 0 and base_picker.align(icon, icon_width, { align = 'right' }) or ''),
        },
      }

      function picker_item:to_string()
        return table.concat({ self.parts[1], self.parts[2] or '', self.parts[3] or '' }, ' ')
      end

      function picker_item:to_formatted_text()
        return {
          { self.parts[1] },
          self.parts[2] and { ' ' .. self.parts[2], 'OpencodeHint' } or { '' },
          self.parts[3] and { ' ' .. self.parts[3], 'OpencodeHint' } or { '' },
        }
      end

      return picker_item
    end,
    actions = {
      toggle_favorite = {
        key = config.keymap.model_picker.toggle_favorite,
        label = 'Toggle favorite',
        fn = function(selected)
          if not selected then
            return models
          end

          model_state.toggle_favorite(selected.provider, selected.model)

          return M._get_models()
        end,
        reload = true,
      } --[[@as PickerAction]],
    },
    callback = function(selection)
      if selection then
        model_state.record_model_access(selection.provider, selection.model)
      end
      cb(selection)
    end,
  })
end

return M
