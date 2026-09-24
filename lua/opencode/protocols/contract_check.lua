local transport = require('opencode.transport')
local Promise = require('opencode.promise')
local log = require('opencode.log')

local M = {}

---The /openapi.json fixture version the offline spec and this check are
---anchored at; regenerate the fixture together with this when re-anchoring.
M.anchored_version = '2.0.14'

---Surface drift to the user with a direction: a server newer than our
---anchor needs a plugin update, an older server needs a CLI update.
---@param version string|nil
---@param count integer
function M.notify_drift(version, count)
  local anchored = vim.version.parse(M.anchored_version)
  local live = vim.version.parse(tostring(version or ''))
  local hint
  if live and anchored and live > anchored then
    hint = 'update this plugin to match your opencode ' .. tostring(version)
  elseif live and anchored and live < anchored then
    hint = 'update the opencode CLI to match this plugin'
  else
    hint = 'update the opencode CLI or this plugin so versions match'
  end
  vim.notify(
    ('opencode API drift: %d endpoint(s) missing on opencode %s. %s.'):format(count, tostring(version or '?'), hint),
    vim.log.levels.WARN,
    { title = 'opencode.nvim' }
  )
end

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
        M.notify_drift(connection.version, #missing)
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
