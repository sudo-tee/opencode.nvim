local state = require('opencode.state')
local config_file = require('opencode.config_file')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local ui = require('opencode.ui.ui')

local M = {}

function M.configure_provider()
  require('opencode.model_picker').select(function(selection)
    if not selection then
      if state.ui.is_visible() then
        ui.focus_input()
      end
      return
    end
    local model_str = string.format('%s/%s', selection.provider, selection.model)
    state.model.set_model(model_str)

    if state.current_mode then
      state.model.set_mode_model_override(state.current_mode, model_str)
    end

    if state.ui.is_visible() then
      ui.focus_input()
    else
      log.notify('Changed provider to ' .. model_str, vim.log.levels.INFO)
    end
  end)
end

function M.configure_variant()
  require('opencode.variant_picker').select(function(selection)
    if not selection then
      if state.ui.is_visible() then
        ui.focus_input()
      end
      return
    end

    state.model.set_variant(selection.name)

    if state.ui.is_visible() then
      ui.focus_input()
    else
      log.notify('Changed variant to ' .. selection.name, vim.log.levels.INFO)
    end
  end)
end

M.cycle_variant = Promise.async(function()
  if not state.current_model then
    log.notify('No model selected', vim.log.levels.WARN)
    return
  end

  local provider, model = state.current_model:match('^(.-)/(.+)$')
  if not provider or not model then
    return
  end

  local config_file = require('opencode.config_file')
  local model_info = config_file.get_model_info(provider, model)

  if not model_info or not model_info.variants then
    log.notify('Current model does not support variants', vim.log.levels.WARN)
    return
  end

  local variants = {}
  for variant_name, _ in pairs(model_info.variants) do
    table.insert(variants, variant_name)
  end

  util.sort_by_priority(variants, function(item)
    return item
  end, { low = 1, medium = 2, high = 3 })

  if #variants == 0 then
    return
  end

  local total_count = #variants + 1

  local current_index
  if state.current_variant == nil then
    current_index = total_count
  else
    current_index = util.index_of(variants, state.current_variant) or 0
  end

  local next_index = (current_index % total_count) + 1

  local next_variant
  if next_index > #variants then
    next_variant = nil
  else
    next_variant = variants[next_index]
  end

  state.model.set_variant(next_variant)

  local model_state = require('opencode.model_state')
  model_state.set_variant(provider, model, next_variant)
end)

M.switch_to_mode = Promise.async(function(mode)
  if not mode or mode == '' then
    log.notify('Mode cannot be empty', vim.log.levels.ERROR)
    return false
  end

  local available_agents = config_file.get_opencode_agents():await()

  if not vim.tbl_contains(available_agents, mode) then
    log.notify(
      string.format('Invalid mode "%s". Available modes: %s', mode, table.concat(available_agents, ', ')),
      vim.log.levels.ERROR
    )
    return false
  end

  state.model.set_mode(mode)
  local opencode_config = config_file.get_opencode_config():await() --[[@as OpencodeConfigFile]]

  local agent_config = opencode_config and opencode_config.agent or {}
  local mode_config = agent_config[mode] or {}

  if state.user_mode_model_map[mode] then
    state.model.set_model(state.user_mode_model_map[mode])
  elseif mode_config.model and mode_config.model ~= '' then
    state.model.set_model(mode_config.model)
  elseif opencode_config and opencode_config.model and opencode_config.model ~= '' then
    state.model.set_model(opencode_config.model)
  end
  return true
end)

M.ensure_current_mode = Promise.async(function()
  if state.current_mode == nil then
    local available_agents = config_file.get_opencode_agents():await()

    if not available_agents or #available_agents == 0 then
      log.notify('No available agents found', vim.log.levels.ERROR)
      return false
    end

    local default_mode = require('opencode.config').default_mode

    if default_mode and vim.tbl_contains(available_agents, default_mode) then
      return M.switch_to_mode(default_mode):await()
    else
      return M.switch_to_mode(available_agents[1]):await()
    end
  end
  return true
end)

---@class InitializeCurrentModelOpts
---@field restore_from_messages? boolean Restore model/mode from the most recent session message

---@param opts? InitializeCurrentModelOpts
---@return string|nil The current model
M.initialize_current_model = Promise.async(function(opts)
  opts = opts or {}

  if opts.restore_from_messages and state.messages then
    for i = #state.messages, 1, -1 do
      local msg = state.messages[i]
      if msg and msg.info and msg.info.modelID and msg.info.providerID then
        local model_str = msg.info.providerID .. '/' .. msg.info.modelID
        if state.current_model ~= model_str then
          state.model.set_model(model_str)
        end
        if msg.info.mode and state.current_mode ~= msg.info.mode then
          state.model.set_mode(msg.info.mode)
        end
        return state.current_model
      end
    end
  end

  if state.current_model then
    return state.current_model
  end

  local cfg = config_file.get_opencode_config():await()
  if cfg and cfg.model and cfg.model ~= '' then
    state.model.set_model(cfg.model)
  end

  return state.current_model
end)

return M
