local M = {
  name = 'v1',
  health_path = '/global/health',
  operations = 'opencode.protocols.v1.operations',
  observation = 'opencode.protocols.v1.observation',
}

---@param response? {status: integer, headers?: table<string, string>, body: string}
---@param decode_json fun(response: table|nil, endpoint: string): table|nil, string|nil
---@param invalid_response fun(response: table|nil, endpoint: string): string
---@return table|nil body
---@return string|nil error
function M.decode_probe(response, decode_json, invalid_response)
  local body, err = decode_json(response, M.health_path)
  if not body then
    return nil, err
  end
  if type(body.healthy) ~= 'boolean' then
    return nil, invalid_response(response, M.health_path)
  end
  if not body.healthy then
    return nil, 'server unhealthy'
  end

  local version = body.version
  body.version = type(version) == 'string' and version or 'unknown'
  return body
end

return M
