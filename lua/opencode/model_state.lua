local M = {}

---Get the path to the model state file
---@return string
local function get_model_state_path()
  local home = vim.uv.os_homedir()
  return home .. '/.local/state/opencode/model.json'
end

---Load model state (favorites, recent, and variants) in OpenCode CLI format
---@return table
function M.load()
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

---Save model state (favorites, recent, and variants) in OpenCode CLI format
---@param state table
function M.save(state)
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

---Get the saved variant for a model
---@param provider_id string
---@param model_id string
---@return string|nil
function M.get_variant(provider_id, model_id)
  local state = M.load()
  local key = provider_id .. '/' .. model_id
  return state.variant[key]
end

---Save the variant for a model
---@param provider_id string
---@param model_id string
---@param variant_name string|nil
function M.set_variant(provider_id, model_id, variant_name)
  local state = M.load()
  local key = provider_id .. '/' .. model_id

  if variant_name then
    state.variant[key] = variant_name
  else
    state.variant[key] = nil
  end

  M.save(state)
end

---Record that a model was accessed
---@param provider_id string
---@param model_id string
function M.record_model_access(provider_id, model_id)
  local state = M.load()

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

  M.save(state)
end

---Toggle a model as favorite
---@param provider_id string
---@param model_id string
function M.toggle_favorite(provider_id, model_id)
  local state = M.load()

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

  M.save(state)
end

---Get model index in a state list
---@param provider_id string
---@param model_id string
---@param list table Array of model entries with providerID and modelID
---@return number|nil Index in the list (1-based) or nil if not found
function M.get_model_index(provider_id, model_id, list)
  for i, item in ipairs(list) do
    if item.providerID == provider_id and item.modelID == model_id then
      return i
    end
  end
  return nil
end

return M
