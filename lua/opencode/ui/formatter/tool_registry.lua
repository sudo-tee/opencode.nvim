local builtins = require('opencode.ui.formatter.tools')

local M = {}

---@type table<string, ToolFormatter?>
local overrides = {}

---@param name string
---@return ToolFormatter
local function builtin(name)
  return builtins[name] or (name:match('_') and builtins.mcp) or builtins.tool
end

---Register a tool formatter. Replacing a built-in requires `replace = true`.
---@param name string
---@param formatter ToolFormatter
---@param opts? { replace?: boolean }
function M.register(name, formatter, opts)
  if name == '' then
    error('Tool formatter name must be a non-empty string')
  end
  if overrides[name] then
    error('Tool formatter already registered: ' .. name)
  end
  if builtins[name] and not (opts and opts.replace == true) then
    error('Tool formatter already exists: ' .. name .. ' (pass { replace = true } to override)')
  end
  overrides[name] = formatter
end

---Remove a registered formatter, restoring any built-in formatter.
---@param name string
---@return boolean
function M.unregister(name)
  if not overrides[name] then
    return false
  end
  overrides[name] = nil
  return true
end

---@param name string
---@return boolean
function M.is_override(name)
  return overrides[name] ~= nil
end

---Formatter used by dispatch, including the MCP and generic fallbacks.
---@param name string
---@return ToolFormatter
function M.resolve(name)
  return overrides[name] or builtin(name)
end

---Built-in formatter for a tool, ignoring any active override.
---@param name string
---@return ToolFormatter
function M.fallback(name)
  return builtin(name)
end

---@param name string
---@return fun(part: table): string, string, string
local function builtin_summary(name)
  local builtin_formatter = builtins[name]
  if builtin_formatter and builtin_formatter.summary then
    return builtin_formatter.summary
  end
  return builtins.tool.summary
end

---Summary function for nested tool rows. An override without a summary keeps
---the matching built-in summary, then falls back to the generic tool summary.
---A failing override summary is logged and replaced by the built-in summary.
---@param name string
---@return fun(part: table): string, string, string
function M.summary(name)
  local override = overrides[name]
  local fallback = builtin_summary(name)
  if not (override and override.summary) then
    return fallback
  end
  local custom_summary = override.summary
  return function(part)
    local ok, icon, label, value = pcall(custom_summary, part)
    if ok then
      return icon, label, value
    end
    require('opencode.log').error('Tool summary "%s" failed: %s', name, tostring(icon))
    return fallback(part)
  end
end

return M
