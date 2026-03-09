local store = require('opencode.state.store')

local M = {}

---@param mode string|nil
function M.set_mode(mode)
  return store.set('current_mode', mode)
end

function M.clear_mode()
  return store.set('current_mode', nil)
end

---@param model string|nil
function M.set_model(model)
  return store.set('current_model', model)
end

function M.clear_model()
  return store.set('current_model', nil)
end

---@param info table|nil
function M.set_model_info(info)
  return store.set('current_model_info', info)
end

---@param variant string|nil
function M.set_variant(variant)
  return store.set('current_variant', variant)
end

function M.clear_variant()
  return store.set('current_variant', nil)
end

---@param mode_map table<string, string>
function M.set_mode_model_map(mode_map)
  return store.set('user_mode_model_map', mode_map)
end

---@param mode string
---@param model string
function M.set_mode_model_override(mode, model)
  local state = store.state()
  local mode_map = vim.deepcopy(state.user_mode_model_map)
  mode_map[mode] = model
  return store.set('user_mode_model_map', mode_map)
end

return M
