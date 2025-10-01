local permission_prompt = require('opencode.ui.permission_prompt')
local curl = require('plenary.curl')
local util = require('opencode.util')

---@class PermissionManager
local PermissionManager = {}
PermissionManager.__index = PermissionManager

function PermissionManager.new(base_url)
  return setmetatable({
    base_url = base_url,
    pending_requests = {},
    current_prompt = nil,
    processing = false,
  }, PermissionManager)
end

function PermissionManager:handle_request(event_data)
  if not event_data or not event_data.id then
    return
  end

  local request = {
    id = event_data.id,
    sessionID = event_data.sessionID,
    tool = event_data.tool or 'unknown',
    action = event_data.action or event_data.command or event_data.path or '',
    context = event_data.context,
    time = os.time(),
  }

  table.insert(self.pending_requests, request)

  self:process_queue()
end

function PermissionManager:process_queue()
  if self.processing or #self.pending_requests == 0 then
    return
  end

  if permission_prompt.is_open() then
    return
  end

  self.processing = true
  local request = table.remove(self.pending_requests, 1)

  vim.schedule(function()
    permission_prompt.show(request, function(response)
      self:send_response(request, response)
      self.processing = false
      self:process_queue()
    end)
  end)
end

function PermissionManager:send_response(request, response)
  if not self.base_url or not request.sessionID or not request.id then
    vim.notify('Failed to send permission response: missing required data', vim.log.levels.ERROR)
    return
  end

  local endpoint = string.format('/session/%s/permissions/%s', request.sessionID, request.id)
  local url = self.base_url .. endpoint
  local body = { response = response }

  vim.schedule(function()
    curl.post(url, {
      body = vim.json.encode(body),
      headers = { ['Content-Type'] = 'application/json' },
      callback = function(res)
        if res.status >= 200 and res.status < 300 then
          if response == 'allow' then
            vim.notify(string.format('Permission granted for %s', request.tool), vim.log.levels.INFO)
          else
            vim.notify(string.format('Permission denied for %s', request.tool), vim.log.levels.WARN)
          end
        else
          vim.notify(
            string.format('Failed to send permission response: HTTP %d', res.status),
            vim.log.levels.ERROR
          )
        end
      end,
      on_error = function(err)
        vim.notify(
          string.format('Failed to send permission response: %s', vim.inspect(err)),
          vim.log.levels.ERROR
        )
      end,
    })
  end)
end

function PermissionManager:clear()
  self.pending_requests = {}
  self.processing = false
  permission_prompt.close()
end

function PermissionManager:update_base_url(base_url)
  self.base_url = base_url
end

return PermissionManager
