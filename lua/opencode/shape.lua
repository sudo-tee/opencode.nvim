-- Small runtime validator. Shorthand rules handle simple type guards;
-- explicit schemas handle composition and transformations.
local M = {}

---@alias OpencodeShapeRule string|(fun(value: any): boolean)|table|OpencodeShapeSchema<any>
---@alias OpencodeShapeParser fun(value: any, path: string): boolean, any
---@alias OpencodeShapeRuleParser fun(value: any, rule: OpencodeShapeRule, path: string): boolean, any
---@class OpencodeShapeObjectOptions
---@field strict? boolean
---@class OpencodeShapeSchema<T>
---@field __index OpencodeShapeSchema<any>
---@field _parse OpencodeShapeParser
---@field parse fun(self: OpencodeShapeSchema<T>, value: any, message?: string): T
---@field safe_parse fun(self: OpencodeShapeSchema<T>, value: any): OpencodeShapeResult<T>
---@field check fun(self: OpencodeShapeSchema<T>, value: any): boolean
---@field is fun(self: OpencodeShapeSchema<T>, value: any): boolean
---@field optional fun(self: OpencodeShapeSchema<T>): OpencodeShapeSchema<T|nil>
---@field nullable fun(self: OpencodeShapeSchema<T>): OpencodeShapeSchema<T|nil>
---@field array fun(self: OpencodeShapeSchema<T>): OpencodeShapeSchema<T[]>
---@field constraint fun(self: OpencodeShapeSchema<T>, fn: (fun(value: T): boolean), message?: string): OpencodeShapeSchema<T>
---@field min fun(self: OpencodeShapeSchema<T>, value: number): OpencodeShapeSchema<T>
---@field max fun(self: OpencodeShapeSchema<T>, value: number): OpencodeShapeSchema<T>
---@field transform fun(self: OpencodeShapeSchema<T>, fn: fun(value: T): any): OpencodeShapeSchema<any>
---@field convert fun(self: OpencodeShapeSchema<T>, fn: fun(value: T): any): OpencodeShapeSchema<any>
---@field or_ fun(self: OpencodeShapeSchema<T>, other: OpencodeShapeRule): OpencodeShapeSchema<T>
---@class OpencodeShapeResult<T>
---@field success boolean
---@field data? T
---@field error? string

local Schema = {}
---@cast Schema OpencodeShapeSchema<any>
Schema.__index = Schema

local function is_schema(value)
  if type(value) ~= 'table' then
    return false
  end
  return getmetatable(value) == Schema
end

local function issue(path, expected, value)
  return string.format('%s: expected %s, got %s', path, expected, type(value))
end

local function path_field(path, field)
  if type(field) == 'string' and field:match('^[%a_][%w_]*$') then
    return path .. '.' .. field
  end
  return path .. '[' .. tostring(field) .. ']'
end

local function sequence_length(value)
  ---@type number
  local length = 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
      return nil
    end
    length = math.max(length, key)
  end
  for index = 1, length do
    if rawget(value, index) == nil then
      return nil
    end
  end
  return length
end

local function is_sequence(value)
  return sequence_length(value) ~= nil
end

---@param parser OpencodeShapeParser
---@return OpencodeShapeSchema<any>
local function new_schema(parser)
  return setmetatable({ _parse = parser }, Schema)
end

local function copy_table(value)
  local result = {}
  for key, entry in pairs(value) do
    result[key] = entry
  end
  return result
end

---@param value any
---@param spec table<any, OpencodeShapeRule>
---@param path string
---@param strict boolean
---@param parse OpencodeShapeRuleParser
---@return boolean, any
local function parse_object(value, spec, path, strict, parse)
  if type(value) ~= 'table' then
    return false, issue(path, 'table', value)
  end

  local fields = {}
  local changed = false
  for field, rule in pairs(spec) do
    local ok, parsed = parse(value[field], rule, path_field(path, field))
    if not ok then
      return false, parsed
    end
    fields[#fields + 1] = { field, parsed }
    changed = changed or parsed ~= value[field]
  end

  if strict then
    for field in pairs(value) do
      if spec[field] == nil then
        return false, path_field(path, field) .. ': unexpected field'
      end
    end
  end

  if not changed then
    return true, value
  end
  local result = copy_table(value)
  for _, field in ipairs(fields) do
    result[field[1]] = field[2]
  end
  return true, result
end

---@param value any
---@param item OpencodeShapeRule
---@param path string
---@param parse OpencodeShapeRuleParser
---@return boolean, any
local function parse_array(value, item, path, parse)
  local length = type(value) == 'table' and sequence_length(value) or nil
  if length == nil then
    return false, issue(path, 'array', value)
  end

  local result = {}
  local changed = false
  for index = 1, length do
    local ok, parsed = parse(value[index], item, path .. '[' .. index .. ']')
    if not ok then
      return false, parsed
    end
    result[index] = parsed
    changed = changed or parsed ~= value[index]
  end
  return true, changed and result or value
end

---@param value any
---@param rule OpencodeShapeRule
---@param path string
---@return boolean, any
local function parse_rule(value, rule, path)
  if is_schema(rule) then
    ---@cast rule OpencodeShapeSchema<any>
    return rule._parse(value, path)
  end

  if type(rule) == 'string' then
    if type(value) == rule then
      return true, value
    end
    return false, issue(path, rule, value)
  end

  if type(rule) == 'function' then
    local ok, valid = pcall(rule, value)
    if ok and valid then
      return true, value
    end
    return false, issue(path, 'predicate', value)
  end

  if type(rule) == 'table' then
    if is_sequence(rule) and #rule > 0 then
      for _, expected in ipairs(rule) do
        if value == expected then
          return true, value
        end
      end
      return false, issue(path, 'one of listed values', value)
    end
    ---@cast rule table<any, OpencodeShapeRule>
    return parse_object(value, rule, path, false, parse_rule)
  end

  return false, path .. ': invalid shape rule'
end

local function primitive(expected)
  return new_schema(function(value, path)
    if type(value) == expected then
      return true, value
    end
    return false, issue(path, expected, value)
  end)
end

---@param value any
---@param message? string
---@return any
function Schema:parse(value, message)
  local ok, result = self._parse(value, '$')
  if not ok then
    error(message ~= nil and tostring(message) or result, 0)
  end
  return result
end

---@param value any
---@return OpencodeShapeResult<any>
function Schema:safe_parse(value)
  local ok, result = pcall(self.parse, self, value)
  if ok then
    return { success = true, data = result }
  end
  return { success = false, error = tostring(result) }
end

---@param value any
---@return boolean
function Schema:check(value)
  local ok, valid = pcall(self._parse, value, '$')
  return ok and valid == true
end

Schema.is = Schema.check

function Schema:optional()
  return M.optional(self)
end

function Schema:nullable()
  return M.nullable(self)
end

function Schema:array()
  return M.array(self)
end

---@param predicate fun(value: any): boolean
---@param description? string
---@return OpencodeShapeSchema<any>
function Schema:constraint(predicate, description)
  local source = self
  return new_schema(function(value, path)
    local ok, parsed = source._parse(value, path)
    if not ok then
      return false, parsed
    end
    local valid, result = pcall(predicate, parsed)
    if valid and result then
      return true, parsed
    end
    return false, issue(path, description or 'constrained value', parsed)
  end)
end

---@param minimum number
---@return OpencodeShapeSchema<number>
function Schema:min(minimum)
  return self:constraint(function(value)
    return value >= minimum
  end, 'at least ' .. tostring(minimum))
end

---@param maximum number
---@return OpencodeShapeSchema<number>
function Schema:max(maximum)
  return self:constraint(function(value)
    return value <= maximum
  end, 'at most ' .. tostring(maximum))
end

---@param transformer fun(value: any): any
---@return OpencodeShapeSchema<any>
function Schema:transform(transformer)
  local source = self
  return new_schema(function(value, path)
    local ok, parsed = source._parse(value, path)
    if not ok then
      return false, parsed
    end
    local transformed, result = pcall(transformer, parsed)
    if not transformed then
      return false, path .. ': transform failed: ' .. tostring(result)
    end
    return true, result
  end)
end

---@param converter fun(value: any): any
---@return OpencodeShapeSchema<any>
function Schema:convert(converter)
  return self:transform(function(value)
    local result = converter(value)
    if result == nil then
      error('conversion returned nil', 0)
    end
    return result
  end)
end

function Schema:or_(other)
  return M.union(self, other)
end

---@param value any
---@param spec OpencodeShapeRule
---@param message? string
---@return any
function M.validate(value, spec, message)
  local ok, result = parse_rule(value, spec, '$')
  if not ok then
    error(message ~= nil and tostring(message) or result, 0)
  end
  return result
end

M.parse = M.validate

---@param condition boolean
---@param message string
---@return boolean
function M.expect(condition, message)
  if not condition then
    error(tostring(message), 0)
  end
  return condition
end

M.assert = M.expect

---@param value any
---@param spec OpencodeShapeRule
---@return boolean
function M.check(value, spec)
  local ok, valid = pcall(parse_rule, value, spec, '$')
  return ok and valid == true
end

M.is = M.check

---@param value any
---@param spec OpencodeShapeRule
---@param message? string
---@return OpencodeShapeResult<any>
function M.safe_parse(value, spec, message)
  local ok, result = pcall(M.validate, value, spec, message)
  if ok then
    return { success = true, data = result }
  end
  return { success = false, error = tostring(result) }
end

---@param spec table<any, OpencodeShapeRule>
---@param options? OpencodeShapeObjectOptions
---@return OpencodeShapeSchema<table>
function M.object(spec, options)
  options = options or {}
  return new_schema(function(value, path)
    return parse_object(value, spec, path, options.strict == true, parse_rule)
  end)
end

---@param spec table<any, OpencodeShapeRule>
---@return OpencodeShapeSchema<table>
function M.strict_object(spec)
  return M.object(spec, { strict = true })
end

---@generic T
---@param item? OpencodeShapeRule
---@return OpencodeShapeSchema<T[]>
function M.array(item)
  item = item or M.any()
  return new_schema(function(value, path)
    return parse_array(value, item, path, parse_rule)
  end)
end

---@generic T
---@param values T[]
---@return OpencodeShapeSchema<T>
function M.enum(values)
  return new_schema(function(value, path)
    for _, expected in ipairs(values) do
      if value == expected then
        return true, value
      end
    end
    return false, issue(path, 'one of listed values', value)
  end)
end

M.one_of = M.enum

---@generic T
---@param expected T
---@return OpencodeShapeSchema<T>
function M.literal(expected)
  return new_schema(function(value, path)
    if value == expected then
      return true, value
    end
    return false, issue(path, 'literal ' .. tostring(expected), value)
  end)
end

---@param first OpencodeShapeRule|OpencodeShapeRule[]
---@param ... OpencodeShapeRule
---@return OpencodeShapeSchema<any>
function M.union(first, ...)
  ---@type OpencodeShapeRule[]
  local options
  if type(first) == 'table' and not is_schema(first) and is_sequence(first) then
    ---@cast first OpencodeShapeRule[]
    options = first
  else
    options = { first, ... }
  end
  return new_schema(function(value, path)
    for _, rule in ipairs(options) do
      local ok, parsed = parse_rule(value, rule, path)
      if ok then
        return true, parsed
      end
    end
    return false, issue(path, 'one of union schemas', value)
  end)
end

---@generic T
---@param rule OpencodeShapeRule
---@return OpencodeShapeSchema<T|nil>
function M.optional(rule)
  return new_schema(function(value, path)
    if value == nil then
      return true, nil
    end
    return parse_rule(value, rule, path)
  end)
end

M.nullable = M.optional

---@generic T
---@param predicate fun(value: any): boolean
---@param description? string
---@return OpencodeShapeSchema<T>
function M.custom(predicate, description)
  return new_schema(function(value, path)
    local ok, valid = pcall(predicate, value)
    if ok and valid then
      return true, value
    end
    return false, issue(path, description or 'predicate', value)
  end)
end

---@generic T
---@param rule OpencodeShapeRule
---@param predicate fun(value: T): boolean
---@param description? string
---@return OpencodeShapeSchema<T>
function M.constraint(rule, predicate, description)
  local schema = new_schema(function(value, path)
    return parse_rule(value, rule, path)
  end)
  return schema:constraint(predicate, description)
end

---@return OpencodeShapeSchema<any>
function M.any()
  return new_schema(function(value)
    return true, value
  end)
end

M.unknown = M.any

---@return OpencodeShapeSchema<string>
function M.string()
  return primitive('string')
end

---@return OpencodeShapeSchema<number>
function M.number()
  return primitive('number')
end

---@return OpencodeShapeSchema<boolean>
function M.boolean()
  return primitive('boolean')
end

---@return OpencodeShapeSchema<function>
M['function'] = function()
  return primitive('function')
end

---@return OpencodeShapeSchema<thread>
function M.thread()
  return primitive('thread')
end

---@return OpencodeShapeSchema<userdata>
function M.userdata()
  return primitive('userdata')
end

---@return OpencodeShapeSchema<table>
function M.table()
  return primitive('table')
end

---@return OpencodeShapeSchema<integer>
function M.integer()
  local schema = M.constraint(M.number(), function(value)
    return value % 1 == 0
  end, 'integer')
  ---@cast schema OpencodeShapeSchema<integer>
  return schema
end

---@generic T, U
---@param rule OpencodeShapeRule
---@param transformer fun(value: T): U
---@return OpencodeShapeSchema<U>
function M.transform(rule, transformer)
  local schema = new_schema(function(value, path)
    return parse_rule(value, rule, path)
  end)
  return schema:transform(transformer)
end

---@generic T, U
---@param rule OpencodeShapeRule
---@param converter fun(value: T): U
---@return OpencodeShapeSchema<U>
function M.convert(rule, converter)
  local schema = new_schema(function(value, path)
    return parse_rule(value, rule, path)
  end)
  return schema:convert(converter)
end

setmetatable(M, {
  __call = function(_, value, spec, message)
    return M.validate(value, spec, message)
  end,
})

return M
