local M = {
  config_promise = nil,
  project_promise = nil,
  providers_promise = nil,
}

---@return OpencodeConfigFile|nil
function M.get_opencode_config()
  if not M.config_promise then
    local state = require('opencode.state')
    M.config_promise = state.api_client:get_config()
  end
  local ok, result = pcall(function()
    return M.config_promise:wait()
  end)

  if not ok then
    vim.notify('Error fetching Opencode config: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result --[[@as OpencodeConfigFile|nil]]
end

---@return OpencodeProject|nil
function M.get_opencode_project()
  if not M.project_promise then
    local state = require('opencode.state')
    M.project_promise = state.api_client:get_current_project()
  end
  local ok, result = pcall(function()
    return M.project_promise:wait()
  end)
  if not ok then
    vim.notify('Error fetching Opencode project: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result --[[@as OpencodeProject|nil]]
end

---@return OpencodeProvidersResponse|nil
function M.get_opencode_providers()
  if not M.providers_promise then
    local state = require('opencode.state')
    M.providers_promise = state.api_client:list_providers()
  end
  local ok, result = pcall(function()
    return M.providers_promise:wait()
  end)
  if not ok then
    vim.notify('Error fetching Opencode providers: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result --[[@as OpencodeProvidersResponse|nil]]
end

function M.get_model_info(provider, model)
  local config_file = require('opencode.config_file')
  local providers = config_file.get_opencode_providers() or {}
  local filtered_providers = vim.tbl_filter(function(p)
    return p.id == provider
  end, providers.providers)

  if #filtered_providers == 0 then
    return nil
  end

  return filtered_providers[1] and filtered_providers[1].models and filtered_providers[1].models[model] or nil
end

function M.get_opencode_agents()
  local cfg = M.get_opencode_config() --[[@as OpencodeConfigFile]]
  if not cfg then
    return {}
  end
  local agents = {}
  for agent, opts in pairs(cfg.agent or {}) do
    -- Only include agents that are enabled and have the right mode
    if opts.disable ~= true and (opts.mode == 'primary' or opts.mode == 'all') then
      table.insert(agents, agent)
    end
  end

  -- Sort the agents before prepending the default agents
  table.sort(agents)

  -- Only add build/plan as fallbacks if they're not explicitly disabled in config
  for _, mode in ipairs({ 'plan', 'build' }) do
    if not vim.tbl_contains(agents, mode) then
      local mode_config = cfg.agent and cfg.agent[mode]
      -- Only add if not explicitly disabled or if no config exists (default behavior)
      if mode_config == nil or (mode_config.disable ~= true) then
        table.insert(agents, 1, mode)
      end
    end
  end
  return agents
end

function M.get_subagents()
  local cfg = M.get_opencode_config()
  if not cfg then
    return {}
  end

  local subagents = {}
  for agent, opts in pairs(cfg.agent or {}) do
    if opts.mode ~= 'primary' or opts.mode == 'all' then
      table.insert(subagents, agent)
    end
  end
  table.insert(subagents, 1, 'general')

  return subagents
end

function M.get_user_commands()
  local cfg = M.get_opencode_config() --[[@as OpencodeConfigFile]]
  return cfg and cfg.command or nil
end

function M.get_mcp_servers()
  local cfg = M.get_opencode_config() --[[@as OpencodeConfigFile]]
  return cfg and cfg.mcp or nil
end

---Does this opencode user command take arguments?
---@param command OpencodeCommand
---@return boolean
function M.command_takes_arguments(command)
  return command.template and command.template:find('$ARGUMENTS') ~= nil or false
end

return M
