local Promise = require('opencode.promise')
local M = {
  config_promise = nil,
  project_promise = nil,
  providers_promise = nil,
}

---@type fun(): Promise<OpencodeConfigFile|nil>
M.get_opencode_config = Promise.async(function()
  if not M.config_promise then
    local state = require('opencode.state')
    M.config_promise = state.api_client:get_config()
  end
  local ok, result = pcall(function()
    return M.config_promise:await()
  end)

  if not ok then
    vim.notify('Error fetching Opencode config: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result
end)

---@type fun(): Promise<OpencodeProject|nil>
M.get_opencode_project = Promise.async(function()
  if not M.project_promise then
    local state = require('opencode.state')
    M.project_promise = state.api_client:get_current_project()
  end
  local ok, result = pcall(function()
    return M.project_promise:await()
  end)
  if not ok then
    vim.notify('Error fetching Opencode project: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result --[[@as OpencodeProject|nil]]
end)

---Get the snapshot storage path for the current workspace
---@type fun(): Promise<string>
M.get_workspace_snapshot_path = Promise.async(function()
  local project = M.get_opencode_project():await() --[[@as OpencodeProject|nil]]
  if not project then
    return ''
  end
  local home = vim.uv.os_homedir()
  return home .. '/.local/share/opencode/snapshot/' .. project.id
end)

---@return Promise<OpencodeProvidersResponse|nil>
function M.get_opencode_providers()
  if not M.providers_promise then
    local state = require('opencode.state')
    M.providers_promise = state.api_client:list_providers()
  end
  return M.providers_promise:catch(function(err)
    vim.notify('Error fetching Opencode providers: ' .. vim.inspect(err), vim.log.levels.ERROR)
    return nil
  end)
end

M.get_model_info = function(provider, model)
  local providers_response = M.get_opencode_providers():peek()

  local providers = providers_response and providers_response.providers or {}

  local filtered_providers = vim.tbl_filter(function(p)
    return p.id == provider
  end, providers)

  if #filtered_providers == 0 then
    return nil
  end

  return filtered_providers[1] and filtered_providers[1].models and filtered_providers[1].models[model] or nil
end

---@type fun(): Promise<string[]>
M.get_opencode_agents = Promise.async(function()
  local cfg = M.get_opencode_config():await()
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

  table.sort(agents)

  for _, mode in ipairs({ 'plan', 'build' }) do
    if not vim.tbl_contains(agents, mode) then
      local mode_config = cfg.agent and cfg.agent[mode]
      if mode_config == nil or (mode_config.disable ~= true) then
        table.insert(agents, 1, mode)
      end
    end
  end
  return agents
end)

---@type fun(): Promise<string[]>
M.get_subagents = Promise.async(function()
  local cfg = M.get_opencode_config():await()
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
end)

---@type fun(): Promise<table<string, table>|nil>
M.get_user_commands = Promise.async(function()
  local cfg = M.get_opencode_config():await()
  return cfg and cfg.command or nil
end)

---@type fun(): Promise<table<string, table>|nil>
M.get_mcp_servers = Promise.async(function()
  local cfg = M.get_opencode_config():await()
  return cfg and cfg.mcp or nil
end)

---Does this opencode user command take arguments?
---@param command OpencodeCommand
---@return boolean
function M.command_takes_arguments(command)
  return command.template and command.template:find('$ARGUMENTS') ~= nil or false
end

return M
