local M = {}

---@type table<string, fun(output: Output): nil>
local formatters = {}

---Controllers register their synthetic part presentation without making the
---message formatter load interactive windows or dispatch commands.
---@param part_type string
---@param format fun(output: Output): nil
function M.register(part_type, format)
  formatters[part_type] = format
end

---@param part_type string
---@param output Output
---@return boolean handled
function M.format(part_type, output)
  local format = formatters[part_type]
  if not format then
    return false
  end
  format(output)
  return true
end

return M
