local state = require('opencode.state')
local config_file = require('opencode.config_file')
local util = require('opencode.util')
local Promise = require('opencode.promise')
local log = require('opencode.log')
local ui = require('opencode.ui.ui')

local M = {}

local function active_session_fact()
  local observation = state.session.active_observation()
  return observation and observation:read().session or nil
end

function M.configure_provider()
  return require('opencode.model_picker').select(function(selection)
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
  return require('opencode.variant_picker').select(function(selection)
    if not selection then
      if state.ui.is_visible() then
        ui.focus_input()
      end
      return
    end

    state.model.set_variant(selection.value)

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
  config_file.get_opencode_providers():await()
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

--- Apply mode and resolve its associated model from config.
--- No session guards; callers are responsible for validation.
---@param mode string
local apply_mode = Promise.async(function(mode)
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
end)

M.switch_to_mode = Promise.async(function(mode)
  local session = active_session_fact()
  if session and session.parentID then
    log.notify('Cannot switch agent in child session', vim.log.levels.WARN)
    return false
  end

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

  apply_mode(mode):await()
  return true
end)

M.ensure_current_mode = Promise.async(function()
  local available_agents = config_file.get_opencode_agents():await()
  if not available_agents or #available_agents == 0 then
    log.notify('No available agents found', vim.log.levels.ERROR)
    return false
  end
  if state.current_mode and vim.tbl_contains(available_agents, state.current_mode) then
    return true
  end
  local default_mode = require('opencode.config').default_mode
  local mode = (default_mode and vim.tbl_contains(available_agents, default_mode)) and default_mode
    or available_agents[1]
  apply_mode(mode):await()
  return true
end)

---@class InitializeCurrentModelOpts
---@field restore_from_messages? boolean Restore model/mode from the most recent session message

---@param opts? InitializeCurrentModelOpts
---@return string|nil The current model
M.initialize_current_model = Promise.async(function(opts)
  opts = opts or {}

  local observation = state.session.active_observation()
  local observed = observation and observation:read() or nil
  if opts.restore_from_messages and observed then
    local order = observed.entry_order or {}
    local is_child = observed.session and observed.session.parentID ~= nil
    local start_idx, end_idx, step = #order, 1, -1
    if is_child then
      start_idx, end_idx, step = 1, #order, 1
    end
    for i = start_idx, end_idx, step do
      local entry = observed.entries_by_id[order[i]]
      if entry and entry.model and entry.model.modelID and entry.model.providerID then
        local model_str = entry.model.providerID .. '/' .. entry.model.modelID
        if state.current_model ~= model_str then
          state.model.set_model(model_str)
        end
        if entry.agent and state.current_mode ~= entry.agent then
          local should_restore_mode = is_child
          if not should_restore_mode then
            local available_agents = config_file.get_opencode_agents():await()
            should_restore_mode = vim.tbl_contains(available_agents, entry.agent)
          end
          if should_restore_mode then
            state.model.set_mode(entry.agent)
          end
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
  else
    local catalog = config_file.get_opencode_providers():await()
    local providers = vim.tbl_keys(catalog and catalog.default or {})
    table.sort(providers)
    local provider = providers[1]
    if provider and catalog.default[provider] then
      state.model.set_model(provider .. '/' .. catalog.default[provider])
    end
  end

  return state.current_model
end)

return M
