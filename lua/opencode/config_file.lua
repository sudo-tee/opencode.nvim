local core = require('opencode.core')

local M = {
  _cache = nil,
}

function M.setup()
  vim.schedule(function()
    core.run_server_api('/config', 'GET', nil, {
      background = true,
      on_done = function(response)
        if not response then
          vim.notify('Failed to parse config file from server response', vim.log.levels.ERROR)
          return
        end
        M._cache = response
      end,
      on_error = function(err)
        vim.notify('Error fetching config file from server: ' .. tostring(err), vim.log.levels.ERROR)
      end,
    })
  end)
end

function M.get_opencode_config()
  return M._cache
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
