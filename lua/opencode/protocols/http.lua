local transport = require('opencode.transport')
local url_encode = require('opencode.util').url_encode

local M = {}

function M.query_string(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys)
  local result = {}
  for _, key in ipairs(keys) do
    local value = values[key]
    if value ~= nil then
      if type(value) == 'table' then
        local nested_keys = vim.tbl_keys(value)
        table.sort(nested_keys)
        for _, nested_key in ipairs(nested_keys) do
          local nested_value = value[nested_key]
          if nested_value ~= nil then
            result[#result + 1] = url_encode(key .. '.' .. nested_key) .. '=' .. url_encode(tostring(nested_value))
          end
        end
      else
        result[#result + 1] = url_encode(key) .. '=' .. url_encode(tostring(value))
      end
    end
  end
  return #result > 0 and table.concat(result, '&') or nil
end

function M.map_paths(value, path_map)
  if type(value) ~= 'table' or type(path_map) ~= 'function' then
    return value
  end
  local mapped = {}
  for key, item in pairs(value) do
    if
      type(item) == 'string'
      and (
        key == 'filePath'
        or key == 'path'
        or key == 'file'
        or key == 'directory'
        or key == 'cwd'
        or key == 'root'
        or key == 'worktree'
      )
    then
      mapped[key] = path_map(item)
    elseif type(item) == 'table' and (key == 'files' or key == 'deleted_files') then
      local paths_only = true
      for _, path in ipairs(item) do
        paths_only = paths_only and type(path) == 'string'
      end
      if paths_only then
        mapped[key] = {}
        for index, path in ipairs(item) do
          mapped[key][index] = path_map(path)
        end
      else
        mapped[key] = M.map_paths(item, path_map)
      end
    elseif type(item) == 'table' then
      mapped[key] = M.map_paths(item, path_map)
    else
      mapped[key] = item
    end
  end
  return mapped
end

function M.location_directory(protocol, location, path_map)
  if type(location) ~= 'table' or type(location.directory) ~= 'string' or location.directory == '' then
    error(protocol .. ' operation requires an explicit location')
  end
  return type(path_map) == 'function' and path_map(location.directory) or location.directory
end

local function request_error(operation, response)
  error(string.format('%s HTTP %d: %s', operation, response.status, response.body), 0)
end

local function decode(operation, response)
  if response.status < 200 or response.status >= 300 then
    request_error(operation, response)
  end
  if response.status == 204 then
    error(operation .. ' returned an empty response', 0)
  end
  local ok, value = pcall(vim.json.decode, response.body)
  if not ok then
    error(operation .. ' returned invalid JSON', 0)
  end
  return value
end

function M.json_request(connection, operation, method, path, query, body, path_map)
  return transport
    .request(connection, {
      method = method,
      path = path,
      query = query and M.query_string(query) or nil,
      body = body ~= nil and vim.json.encode(M.map_paths(body, path_map)) or nil,
    })
    :and_then(function(response)
      return decode(operation, response)
    end)
end

function M.require_table(operation, value)
  if type(value) ~= 'table' then
    error(operation .. ' returned an invalid response', 0)
  end
  return value
end

return M
