local M = {}

-- ID prefixes mapping
local prefixes = {
  session = 'ses',
  message = 'msg',
  permission = 'per',
  user = 'usr',
  part = 'prt',
}

-- State for monotonic ID generation
local last_timestamp = 0
local counter = 0

local LENGTH = 26

-- Generate random base62 string
local function random_base62(length)
  local chars = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
  local parts = {}

  for i = 1, length do
    local rand = math.random(1, 62)
    parts[i] = chars:sub(rand, rand)
  end

  return table.concat(parts)
end

-- Convert number to hex string with padding
local function to_hex_padded(num, bytes)
  local hex = string.format('%x', num)
  local padding = bytes * 2 - #hex
  if padding > 0 then
    hex = string.rep('0', padding) .. hex
  end
  return hex:sub(1, bytes * 2)
end

-- Bitwise operations for Lua 5.1 compatibility
local function band(a, b)
  local result = 0
  local bit_val = 1
  while a > 0 and b > 0 do
    if a % 2 == 1 and b % 2 == 1 then
      result = result + bit_val
    end
    bit_val = bit_val * 2
    a = math.floor(a / 2)
    b = math.floor(b / 2)
  end
  return result
end

local function rshift(a, n)
  return math.floor(a / (2 ^ n))
end

local function bnot_48bit(a)
  -- Apply NOT operation to 48 bits (0xFFFFFFFFFFFF)
  return 0xFFFFFFFFFFFF - a
end

-- Generate new ID with timestamp and counter
local function generate_new_id(prefix, descending)
  local current_timestamp = math.floor(vim.loop.hrtime() / 1000000) -- Convert to milliseconds

  if current_timestamp ~= last_timestamp then
    last_timestamp = current_timestamp
    counter = 0
  end
  counter = counter + 1

  -- Create time-based component (48 bits)
  local now = current_timestamp * 0x1000 + counter

  if descending then
    -- Bitwise NOT operation for descending order (48-bit mask)
    now = bnot_48bit(now)
  end

  -- Extract 6 bytes (48 bits) from the timestamp
  local time_parts = {}
  for i = 5, 0, -1 do
    local byte_val = band(rshift(now, i * 8), 0xff)
    time_parts[6 - i] = to_hex_padded(byte_val, 1)
  end
  local time_bytes = table.concat(time_parts)

  -- Generate random suffix
  local random_suffix = random_base62(LENGTH - 12)

  return prefixes[prefix] .. '_' .. time_bytes .. random_suffix
end

-- Generate ID with validation
local function generate_id(prefix, descending, given)
  if not given then
    return generate_new_id(prefix, descending)
  end

  if not vim.startswith(given, prefixes[prefix]) then
    error(string.format('ID %s does not start with %s', given, prefixes[prefix]))
  end

  return given
end

-- Schema validation function
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

-- Generate ascending (chronologically ordered) ID
function M.ascending(prefix, given)
  return generate_id(prefix, false, given)
end

-- Generate descending (reverse chronologically ordered) ID
function M.descending(prefix, given)
  return generate_id(prefix, true, given)
end

-- Get available prefixes
function M.get_prefixes()
  return vim.deepcopy(prefixes)
end

return M

