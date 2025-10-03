local M = {
  config_promise = nil,
  project_promise = nil,
  providers_promise = nil,
}

function M.setup()
  -- No-op: Config is now loaded lazily when needed to avoid spawning server on plugin load
end

---@return OpencodeConfigFile|nil
function M.get_opencode_config()
  if not M.config_promise then
    local state = require('opencode.state')
    M.config_promise = state.api_client:get_config()
  end
  return M.config_promise:wait() --[[@as OpencodeConfigFile|nil]]
end

---@return OpencodeProject|nil
function M.get_opencode_project()
  if not M.project_promise then
    local state = require('opencode.state')
    M.project_promise = state.api_client:get_current_project()
  end
  return M.project_promise:wait() --[[@as OpencodeProject|nil]]
end

---@return OpencodeProvidersResponse|nil
function M.get_opencode_providers()
  if not M.providers_promise then
    local state = require('opencode.state')
    M.providers_promise = state.api_client:list_providers()
  end
  return M.providers_promise:wait() --[[@as OpencodeProvidersResponse|nil]]
end

function M.get_model_info(provider, model)
  local config_file = require('opencode.config_file')
  local providers = vim.tbl_filter(function(p)
    return p.id == provider
  end, config_file.get_opencode_providers().providers)

  if #providers == 0 then
    return nil
  end

  return providers[1] and providers[1].models and providers[1].models[model] or nil
end

function M.get_opencode_agents()
  local cfg = M.get_opencode_config() --[[@as OpencodeConfigFile]]
  if not cfg then
    return {}
  end
  local agents = {}
  for agent, opts in pairs(cfg.agent or {}) do
    if opts.mode == 'primary' or opts.mode == 'all' then
      table.insert(agents, agent)
    end
  end
  for _, mode in ipairs({ 'build', 'plan' }) do
    if not vim.tbl_contains(agents, mode) then
      table.insert(agents, mode)
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

return M
