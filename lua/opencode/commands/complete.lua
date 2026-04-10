local M = {}

---@param items string[]
---@param prefix string
---@return string[]
local function filter_by_prefix(items, prefix)
  return vim.tbl_filter(function(item)
    return vim.startswith(item, prefix)
  end, items)
end

---@return string[]
local function user_command_completions()
  local config_file = require('opencode.config_file')
  local user_commands = config_file.get_user_commands():wait()
  if not user_commands then
    return {}
  end

  local names = vim.tbl_keys(user_commands)
  table.sort(names)
  return names
end

---@type table<string, fun(): string[]>
local provider_completions = {
  user_commands = user_command_completions,
}

---@param subcmd_def OpencodeUICommand
---@param num_parts integer
---@return string[]
local function resolve_subcommand_completions(subcmd_def, num_parts)
  if num_parts <= 3 then
    if type(subcmd_def.completions) == 'table' then
      return subcmd_def.completions --[[@as string[] ]]
    end

    if type(subcmd_def.completion_provider_id) == 'string' then
      local provider = provider_completions[subcmd_def.completion_provider_id]
      return provider and provider() or {}
    end
  end

  if num_parts <= 4 and type(subcmd_def.sub_completions) == 'table' then
    return subcmd_def.sub_completions --[[@as string[] ]]
  end

  return {}
end

---@param command_definitions table<string, OpencodeUICommand>
---@param arg_lead string
---@param cmd_line string
---@return string[]
function M.complete_command(command_definitions, arg_lead, cmd_line)
  local parts = vim.split(cmd_line, '%s+', { trimempty = false })
  local num_parts = #parts

  if num_parts <= 2 then
    local subcommands = vim.tbl_keys(command_definitions)
    table.sort(subcommands)
    return vim.tbl_filter(function(cmd)
      return vim.startswith(cmd, arg_lead)
    end, subcommands)
  end

  local subcommand = parts[2]
  local subcmd_def = command_definitions[subcommand]

  if not subcmd_def then
    return {}
  end

  return filter_by_prefix(resolve_subcommand_completions(subcmd_def, num_parts), arg_lead)
end

return M
