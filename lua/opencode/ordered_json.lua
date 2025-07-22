--- OrderedJson: JSON with key order preservation
---@class OrderedJson
local OrderedJson = {}
OrderedJson.__index = OrderedJson

--- Structure returned by OrderedJson:read
---@class OrderedJsonReadResult
---@field data table
---@field _ordered_keys string[]

---Create a new OrderedJson instance
---@return OrderedJson
function OrderedJson.new()
  return setmetatable({}, OrderedJson)
end

---Check if a table is a contiguous array
---@param tbl table
---@return boolean
function OrderedJson:is_array(tbl)
  if type(tbl) ~= 'table' then
    return false
  end
  local n = #tbl
  for k, _ in pairs(tbl) do
    if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then
      return false
    end
  end
  return n > 0
end

---Read a JSON file and preserve key order
---@param file_path string
---@return OrderedJsonReadResult|nil
function OrderedJson:read(file_path)
  local f = io.open(file_path, 'r')
  if not f then
    vim.notify('Failed to open file ' .. file_path, vim.log.levels.ERROR)
    return nil
  end
  local content = f:read('*a')
  f:close()

  local ordered_keys = {}
  for key in content:gmatch('"([^"]+)":') do
    table.insert(ordered_keys, key)
  end

  local ok, json = pcall(vim.json.decode, content)
  if not ok then
    vim.notify('Failed to decode JSON in ' .. file_path, vim.log.levels.ERROR)
    return nil
  end

  return {
    data = json,
    _ordered_keys = ordered_keys,
  }
end

---Encode a table or OrderedJsonReadResult to a JSON string, preserving key order if present
---@param obj table|OrderedJsonReadResult
---@param indent? string
---@param level? integer
---@return string
function OrderedJson:encode(obj, indent, level)
  indent = indent or '  '
  level = level or 0
  local tbl, ordered_keys
  if type(obj) == 'table' and obj._ordered_keys then
    tbl = obj.data
    ordered_keys = obj._ordered_keys
  else
    tbl = obj
    ordered_keys = nil
  end

  local function encode_value(val, _indent, _level)
    if type(val) == 'table' then
      return self:encode(val, _indent, _level + 1)
    end
    return vim.json.encode(val)
  end

  if self:is_array(tbl) then
    local parts = { '[\n' }
    for i, v in ipairs(tbl) do
      if i > 1 then
        table.insert(parts, ',\n')
      end
      table.insert(parts, string.rep(indent, level + 1))
      table.insert(parts, encode_value(v, indent, level + 1))
    end
    table.insert(parts, '\n' .. string.rep(indent, level) .. ']')
    return table.concat(parts)
  else
    local parts = { '{\n' }
    local first = true
    local function insert_key_value(key, value)
      if not first then
        table.insert(parts, ',\n')
      end
      first = false
      table.insert(parts, string.rep(indent, level + 1))
      table.insert(parts, string.format('"%s": %s', key, encode_value(value, indent, level + 1)))
    end
    if ordered_keys then
      for _, key in ipairs(ordered_keys) do
        if tbl[key] ~= nil then
          insert_key_value(key, tbl[key])
        end
      end
    end
    for key, value in pairs(tbl) do
      if not ordered_keys or not vim.tbl_contains(ordered_keys, key) then
        insert_key_value(key, value)
      end
    end
    table.insert(parts, '\n' .. string.rep(indent, level - 1) .. '}')
    return table.concat(parts)
  end
end

return OrderedJson
