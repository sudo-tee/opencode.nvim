local Promise = require('opencode.promise')
local config_file = require('opencode.config_file')
local commands = require('opencode.commands')
local log = require('opencode.log')

local M = {}

-- Maps slash command -> :Opencode command string (with optional subcommand)
---@type table<string, string>
local slash_command_presets = {
  ['/help']          = 'help',
  ['/agent']         = 'agent select',
  ['/agents_init']   = 'session agents_init',
  ['/child-sessions']= 'session child',
  ['/command-list']  = 'commands_list',
  ['/compact']       = 'session compact',
  ['/history']       = 'history',
  ['/mcp']           = 'mcp',
  ['/models']        = 'models',
  ['/variant']       = 'variant',
  ['/new']           = 'session new',
  ['/redo']          = 'redo',
  ['/sessions']      = 'session select',
  ['/share']         = 'session share',
  ['/timeline']      = 'timeline',
  ['/references']    = 'references',
  ['/undo']          = 'undo',
  ['/unshare']       = 'session unshare',
  ['/rename']        = 'session rename',
  ['/thinking']      = 'toggle_reasoning_output',
  ['/reasoning']     = 'toggle_reasoning_output',
  ['/review']        = 'review',
}

---@return table<string, OpencodeSlashCommandSpec>
local function build_builtin_slash_command_definitions()
  local command_defs = commands.get_commands()
  local slash_defs = {}

  for slash_cmd, cmd_str in pairs(slash_command_presets) do
    local top_cmd = vim.split(cmd_str, ' ', { trimempty = true })[1]
    local command_def = command_defs[top_cmd]
    local desc = 'Run :Opencode ' .. cmd_str
    if command_def and command_def.desc then
      desc = command_def.desc
    end

    slash_defs[slash_cmd] = {
      cmd_str = cmd_str,
      desc = desc,
      args = command_def and command_def.nargs ~= nil or false,
    }
  end

  return slash_defs
end

local builtin_slash_command_definitions = build_builtin_slash_command_definitions()

---@return table<string, OpencodeSlashCommandSpec>
function M.get_builtin_command_definitions()
  return builtin_slash_command_definitions
end

---@param slash_cmd string
---@param def OpencodeSlashCommandSpec
---@return OpencodeSlashCommand|nil
local function to_runtime_slash_command(slash_cmd, def)
  local fn = def.fn
  local cmd_str = def.cmd_str
  if not fn and type(cmd_str) == 'string' then
    fn = function(args)
      local full = cmd_str
      if args and #args > 0 then
        full = full .. ' ' .. table.concat(args, ' ')
      end
      return commands.execute_command_opts({ args = full, range = 0 })
    end
  end

  if type(fn) ~= 'function' then
    log.notify(string.format("Slash command '%s' has no executable handler", slash_cmd), vim.log.levels.WARN)
    return nil
  end

  return {
    slash_cmd = slash_cmd,
    desc = def.desc,
    fn = fn,
    args = def.args or false,
  }
end

M.get_commands = Promise.async(function()
  ---@type OpencodeSlashCommand[]
  local result = {}

  for slash_cmd, def in pairs(M.get_builtin_command_definitions()) do
    local runtime_def = to_runtime_slash_command(slash_cmd, def)
    if runtime_def then
      table.insert(result, runtime_def)
    end
  end

  local user_commands = config_file.get_user_commands():await()
  if user_commands then
    for name, def in pairs(user_commands) do
      table.insert(result, {
        slash_cmd = '/' .. name,
        desc = def.description or 'User command',
        fn = function(args)
          local full = 'command ' .. name
          if args and #args > 0 then
            full = full .. ' ' .. table.concat(args, ' ')
          end
          return commands.execute_command_opts({ args = full, range = 0 })
        end,
        args = true,
      })
    end
  end

  return result
end)

return M
