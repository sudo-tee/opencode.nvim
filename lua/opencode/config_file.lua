local core = require('opencode.core')
local server_job = require('opencode.server_job')

local M = {
  config_cache = nil,
  project_cache = nil,
}

function M.setup()
  vim.schedule(function()
    server_job.with_server(function(server, base_url)
      local on_done = function()
        if M.config_cache and M.project_cache then
          server:shutdown()
        end
      end
      M.fetch_opencode_config(base_url, on_done)
      M.fetch_opencode_project(base_url, on_done)
    end, {
      on_error = function(err)
        vim.notify('Error starting opencode server: ' .. tostring(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

-- Fetch configuration from the opencode server
---@param base_url string The base URL of the opencode server
---@param on_done function Callback function to be called when fetching is done
function M.fetch_opencode_config(base_url, on_done)
  server_job.call_api(base_url .. '/config', 'GET', nil, function(err, response)
    if not response or err then
      vim.notify('Error fetching config file from server', vim.log.levels.ERROR)
      return
    end
    M.config_cache = response
    on_done()
  end)
end

-- Fetch project from the opencode server
---@param base_url string The base URL of the opencode server
---@param on_done function Callback function to be called when fetching is done
function M.fetch_opencode_project(base_url, on_done)
  server_job.call_api(base_url .. '/project/current', 'GET', nil, function(err, response)
    if not response or err then
      vim.notify(
        'Error fetching project info from server. Ensure you have compatible version of opencode',
        vim.log.levels.ERROR
      )

      return
    end
    M.project_cache = response
    on_done()
  end)
end

function M.get_opencode_config()
  return M.config_cache
end

function M.get_opencode_project()
  return M.project_cache
end

function M.get_opencode_agents()
  local cfg = M.get_opencode_config()
  if not cfg then
    return {}
  end

  local agents = {}
  for mode, _ in pairs(cfg.agent or {}) do
    table.insert(agents, mode)
  end

  for _, mode in ipairs({ 'build', 'plan' }) do
    if not vim.tbl_contains(agents, mode) then
      table.insert(agents, mode)
    end
  end

  return agents
end

function M.get_user_commands()
  local cfg = M.get_opencode_config()
  return cfg and cfg.command or nil
end

function M.get_mcp_servers()
  local cfg = M.get_opencode_config()
  return cfg and cfg.mcp or nil
end

return M
