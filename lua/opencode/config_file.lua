local server_job = require('opencode.server_job')
local Promise = require('opencode.promise')

local M = {
  config_promise = nil,
  project_promise = nil,
  setup_promise = nil,
}

function M.setup()
  M.setup_promise = Promise.new()
  vim.schedule(function()
    server_job.with_server(function(server, base_url)
      local function on_done()
        if
          M.config_promise
          and M.config_promise:is_resolved()
          and M.project_promise
          and M.project_promise:is_resolved()
        then
          M.setup_promise:resolve(true)
          server:shutdown()
        end
      end
      M.fetch_opencode_config(base_url):and_then(on_done)
      M.fetch_opencode_project(base_url):and_then(on_done)
    end, {
      on_error = function(err)
        M.setup_promise:reject(err)
        vim.notify('Error starting opencode server: ' .. tostring(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

-- Fetch configuration from the opencode server
---@param base_url string The base URL of the opencode server
---@return Promise
function M.fetch_opencode_config(base_url)
  M.config_promise = M.config_promise
    or server_job.call_api(base_url .. '/config', 'GET'):catch(function(err)
      vim.notify('Error fetching config file from server', vim.log.levels.ERROR)
      error(err)
    end)
  return M.config_promise
end

-- Fetch project from the opencode server
---@param base_url string The base URL of the opencode server
---@return Promise
function M.fetch_opencode_project(base_url)
  M.project_promise = M.project_promise
    or server_job.call_api(base_url .. '/project/current', 'GET'):catch(function(err)
      vim.notify(
        'Error fetching project info from server. Ensure you have compatible version of opencode',
        vim.log.levels.ERROR
      )
      error(err)
    end)
  return M.project_promise
end

---@return OpencodeConfigFile|nil
function M.get_opencode_config()
  M.setup_promise:wait()
  return M.config_promise:wait() --[[@as OpencodeConfigFile|nil]]
end

---@return OpencodeProject|nil
function M.get_opencode_project()
  M.setup_promise:wait()
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
