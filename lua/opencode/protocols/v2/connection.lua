local M = {
  name = 'v2',
  health_path = '/api/info',
  operations = 'opencode.protocols.v2.operations',
  observation = 'opencode.protocols.v2.observation',
}

---@param response? {status: integer, headers?: table<string, string>, body: string}
---@param decode_json fun(response: table, endpoint: string): table|nil, string|nil
---@return table|nil body
---@return string|nil error
---@return boolean fallback_to_v1
function M.decode_probe(response, decode_json)
  if response and response.status == 404 then
    return nil, nil, true
  end

  local body, err = decode_json(response, M.health_path)
  if not body then
    local successful_response = response
      and type(response.status) == 'number'
      and response.status >= 200
      and response.status < 300
    return nil, err, successful_response == true
  end

  local version = body.version
  if type(version) ~= 'string' then
    return nil, nil, true
  end
  if not version:match('^2%.') then
    return nil, 'unsupported v2 server version: ' .. version, false
  end
  return body, nil, false
end

return M
