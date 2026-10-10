local builtins = require('opencode.slash_commands')

local M = {}

---@class OpencodeCustomSlashCommand
---@field name string Name without the leading slash
---@field desc string
---@field args? boolean Whether completion leaves room for arguments
---@field fn fun(args: string[]): any

---@type table<string, OpencodeCustomSlashCommand?>
local registry = {}

---Register a local command. Invalid names and builtin/registered duplicates throw.
---@param spec OpencodeCustomSlashCommand
function M.register(spec)
  if not spec.name:match('^[%w_-]+$') then
    error('Slash command name must contain only letters, digits, underscores, or hyphens')
  end
  for name in pairs(builtins.get_definitions()) do
    if name == '/' .. spec.name then
      error('Slash command already exists: /' .. spec.name)
    end
  end
  if registry[spec.name] then
    error('Slash command already exists: /' .. spec.name)
  end
  registry[spec.name] = vim.deepcopy(spec)
end

---Remove a local command; returns false when not registered.
---@param name string
---@return boolean
function M.unregister(name)
  local found = registry[name] ~= nil
  registry[name] = nil
  return found
end

---@return table<string, OpencodeCustomSlashCommand?>
function M.list()
  return vim.deepcopy(registry)
end

return M
