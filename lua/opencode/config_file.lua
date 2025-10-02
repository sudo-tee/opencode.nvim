local M = {
  config_promise = nil,
  project_promise = nil,
}

function M.setup()
  vim.schedule(function()
    local state = require('opencode.state')
    M.config_promise = state.api_client:get_config()
    M.project_promise = state.api_client:get_current_project()
  end)
end

---@return OpencodeConfigFile|nil
function M.get_opencode_config()
  return M.config_promise:wait() --[[@as OpencodeConfigFile|nil]]
end

---@return OpencodeProject|nil
function M.get_opencode_project()
  return M.project_promise:wait() --[[@as OpencodeProject|nil]]
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
