local M = {}

-- ID prefixes mapping
local prefixes = {
  session = 'ses',
  message = 'msg',
  permission = 'per',
  user = 'usr',
  part = 'prt',
}

local last_timestamp = 0
local counter = 0

local LENGTH = 26
local TIME_MODULUS = 0x1000000000000
local TIME_MASK = TIME_MODULUS - 1

local function random_base62(length)
  local chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
  local bytes = assert(vim.uv.random(length))
  local parts = {}

  for i = 1, length do
    local index = (bytes:byte(i) % 62) + 1
    parts[i] = chars:sub(index, index)
  end

  return table.concat(parts)
end

local function wall_clock_ms()
  local seconds, microseconds = vim.uv.gettimeofday()
  return (seconds * 1000) + math.floor(microseconds / 1000)
end

local function generate_new_id(prefix, descending)
  local current_timestamp = wall_clock_ms()

  if current_timestamp ~= last_timestamp then
    last_timestamp = current_timestamp
    counter = 0
  end
  counter = counter + 1

  local encoded_time = ((current_timestamp * 0x1000) + counter) % TIME_MODULUS

  if descending then
    encoded_time = TIME_MASK - encoded_time
  end

  local time_bytes = string.format('%012x', encoded_time)
  local random_suffix = random_base62(LENGTH - 12)

  return prefixes[prefix] .. '_' .. time_bytes .. random_suffix
end

local function generate_id(prefix, descending, given)
  if not given then
    return generate_new_id(prefix, descending)
  end

  if not vim.startswith(given, prefixes[prefix]) then
    error(string.format('ID %s does not start with %s', given, prefixes[prefix]))
  end

  return given
end

function M.schema(prefix)
  return function(id)
    if type(id) ~= 'string' then
      return false, 'ID must be a string'
    end

    if not prefixes[prefix] then
      return false, 'Invalid prefix: ' .. tostring(prefix)
    end

    if not vim.startswith(id, prefixes[prefix]) then
      return false, string.format('ID must start with %s', prefixes[prefix])
    end

    return true
  end
end

function M.ascending(prefix, given)
  return generate_id(prefix, false, given)
end

function M.descending(prefix, given)
  return generate_id(prefix, true, given)
end

function M.get_prefixes()
  return vim.deepcopy(prefixes)
end

return M
