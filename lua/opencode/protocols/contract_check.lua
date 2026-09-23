local transport = require('opencode.transport')
local Promise = require('opencode.promise')
local log = require('opencode.log')

local M = {}

---Compare the V2 operations contract against the live server's self-declared
---/openapi.json. Returns the list of contract entries the server does not
---offer; a transport failure resolves to nil (check skipped, connection stays
---usable). Warns once per check when drift is found — this never blocks the
---connection: one removed endpoint must not take the whole plugin down.
---@param connection OpencodeServer
---@return Promise<string[]|nil>
function M.check(connection)
  return transport
    .request(connection, { method = 'GET', path = '/openapi.json' })
    :and_then(function(response)
      if type(response.body) ~= 'string' or response.status ~= 200 then
        return nil
      end
      local ok, spec = pcall(vim.json.decode, response.body)
      if not ok or type(spec.paths) ~= 'table' then
        return nil
      end

      local operations = require('opencode.protocols.v2.operations')
      local missing = {}
      for _, entry in ipairs(operations.contract) do
        local method, path = entry[1], entry[2]
        local offered = spec.paths[path]
        if type(offered) ~= 'table' or offered[method:lower()] == nil then
          missing[#missing + 1] = method .. ' ' .. path
        end
      end

      if #missing > 0 then
        log.warn(
          'opencode %s API drift: server openapi lacks %d endpoint(s) used by this plugin: %s',
          tostring(connection.version),
          #missing,
          table.concat(missing, ', ')
        )
      end
      return missing
    end)
    :catch(function()
      return nil
    end)
end

---Fire-and-forget startup check for a ready V2 server.
---@param server OpencodeServer
function M.check_async(server)
  if server.protocol ~= 'v2' then
    return
  end
  Promise.async(function()
    return M.check(server)
  end)()
end

return M
