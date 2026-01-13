local config = require('opencode.config')
local M = {}

---Get the path to the model state file
---@return string
local function get_model_state_path()
  local home = vim.uv.os_homedir()
  return home .. '/.local/state/opencode/model.json'
end

---Load model state (favorites and recent) in OpenCode CLI format
---@return table
local function load_model_state()
  local state_path = get_model_state_path()
  local file = io.open(state_path, 'r')
  if not file then
    return { recent = {}, favorite = {}, variant = {} }
  end

  local content = file:read('*a')
  file:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= 'table' then
    return { recent = {}, favorite = {}, variant = {} }
  end

  data.recent = data.recent or {}
  data.favorite = data.favorite or {}
  data.variant = data.variant or {}

  return data
end

---Save model state (favorites and recent) in OpenCode CLI format
---@param state table
local function save_model_state(state)
  local state_path = get_model_state_path()
  local state_dir = vim.fn.fnamemodify(state_path, ':h')

  if not vim.fn.isdirectory(state_dir) then
    vim.fn.mkdir(state_dir, 'p')
  end

  local file = io.open(state_path, 'w')
  if not file then
    vim.notify('Failed to save model state', vim.log.levels.WARN)
    return
  end

  local ok, json = pcall(vim.json.encode, state)
  if not ok then
    file:close()
    vim.notify('Failed to encode model state', vim.log.levels.WARN)
    return
  end

  file:write(json)
  file:close()
end

---Record that a model was accessed
---@param provider_id string
---@param model_id string
local function record_model_access(provider_id, model_id)
  local state = load_model_state()

  state.recent = vim.tbl_filter(function(item)
    return not (item.providerID == provider_id and item.modelID == model_id)
  end, state.recent)

  table.insert(state.recent, 1, {
    providerID = provider_id,
    modelID = model_id,
  })

  if #state.recent > 10 then
    for i = #state.recent, 11, -1 do
      table.remove(state.recent, i)
    end
  end

  save_model_state(state)
end

---Toggle a model as favorite
---@param provider_id string
---@param model_id string
local function toggle_favorite(provider_id, model_id)
  local state = load_model_state()

  -- Check if already in favorites
  local found_idx = nil
  for i, item in ipairs(state.favorite) do
    if item.providerID == provider_id and item.modelID == model_id then
      found_idx = i
      break
    end
  end

  if found_idx then
    table.remove(state.favorite, found_idx)
    vim.notify('Removed from favorites: ' .. provider_id .. '/' .. model_id, vim.log.levels.INFO)
  else
    table.insert(state.favorite, {
      providerID = provider_id,
      modelID = model_id,
    })
    vim.notify('Added to favorites: ' .. provider_id .. '/' .. model_id, vim.log.levels.INFO)
  end

  save_model_state(state)
end

---Get model index in a state list
---@param provider_id string
---@param model_id string
---@param list table Array of model entries with providerID and modelID
---@return number|nil Index in the list (1-based) or nil if not found
local function get_model_index(provider_id, model_id, list)
  for i, item in ipairs(list) do
    if item.providerID == provider_id and item.modelID == model_id then
      return i
    end
  end
  return nil
end

function M._get_models()
  local config_file = require('opencode.config_file')
  local response = config_file.get_opencode_providers():wait()

  if not response then
    return {}
  end

  local icons = require('opencode.ui.icons')
  local preferred_icon = icons.get('preferred')
  local last_used_icon = icons.get('last_used')

  local state = load_model_state()

  local models = {}
  for _, provider in ipairs(response.providers) do
    for _, model in pairs(provider.models) do
      local provider_id = provider.id
      local model_id = model.id
      local fav_idx = get_model_index(provider_id, model_id, state.favorite)
      local recent_idx = get_model_index(provider_id, model_id, state.recent)

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
        content = base_picker.align(item.model_name, model_width, { truncate = true }),
        time_text = base_picker.align(item.provider_name, max_provider_width, { align = 'left' })
          .. (icon_width > 0 and base_picker.align(icon, icon_width, { align = 'right' }) or ''),
        debug_text = nil,
      }

      function picker_item:to_string()
        return table.concat({ self.content, self.time_text or '', self.debug_text or '' }, ' ')
      end

      function picker_item:to_formatted_text()
        return {
          { self.content },
          self.time_text and { ' ' .. self.time_text, 'OpencodeHint' } or { '' },
          self.debug_text and { ' ' .. self.debug_text, 'OpencodeHint' } or { '' },
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

          toggle_favorite(selected.provider, selected.model)

          return M._get_models()
        end,
        reload = true,
      } --[[@as PickerAction]],
    },
    callback = function(selection)
      if selection then
        record_model_access(selection.provider, selection.model)
      end
      cb(selection)
    end,
  })
end

return M
