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

---@class OpencodeCommandCompleteContext
---@field arg_lead string
---@field num_parts integer
---@field subcmd_def OpencodeUICommand

---@class OpencodeCommandCompleteRule
---@field matches fun(ctx: OpencodeCommandCompleteContext): boolean
---@field resolve fun(ctx: OpencodeCommandCompleteContext): string[]

---@type OpencodeCommandCompleteRule[]
local completion_rules = {
  {
    matches = function(ctx)
      return ctx.num_parts <= 3 and type(ctx.subcmd_def.completions) == 'table'
    end,
    resolve = function(ctx)
      return ctx.subcmd_def.completions --[[@as string[] ]]
    end,
  },
  {
    matches = function(ctx)
      return ctx.num_parts <= 3 and type(ctx.subcmd_def.completion_provider_id) == 'string'
    end,
    resolve = function(ctx)
      local provider_id = ctx.subcmd_def.completion_provider_id --[[@as string ]]
      local provider = provider_completions[provider_id]
      if not provider then
        return {}
      end
      return provider()
    end,
  },
  {
    matches = function(ctx)
      return ctx.num_parts <= 4 and type(ctx.subcmd_def.sub_completions) == 'table'
    end,
    resolve = function(ctx)
      return ctx.subcmd_def.sub_completions --[[@as string[] ]]
    end,
  },
}

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

  local ctx = {
    arg_lead = arg_lead,
    num_parts = num_parts,
    subcmd_def = subcmd_def,
  }

  for _, rule in ipairs(completion_rules) do
    if rule.matches(ctx) then
      return filter_by_prefix(rule.resolve(ctx), arg_lead)
    end
  end

  return {}
end

return M
