local Promise = require('opencode.promise')
local config_file = require('opencode.config_file')
local commands = require('opencode.commands')
local log = require('opencode.log')

local M = {}

---@class OpencodeSlashPreset
---@field name string
---@field preset_args? string[]

---@type table<string, OpencodeSlashPreset>
local slash_command_presets = {
  ['/help'] = { name = 'help' },
  ['/agent'] = { name = 'agent', preset_args = { 'select' } },
  ['/agents_init'] = { name = 'session', preset_args = { 'agents_init' } },
  ['/child-sessions'] = { name = 'session', preset_args = { 'child' } },
  ['/command-list'] = { name = 'commands_list' },
  ['/compact'] = { name = 'session', preset_args = { 'compact' } },
  ['/history'] = { name = 'history' },
  ['/mcp'] = { name = 'mcp' },
  ['/models'] = { name = 'models' },
  ['/variant'] = { name = 'variant' },
  ['/new'] = { name = 'session', preset_args = { 'new' } },
  ['/redo'] = { name = 'redo' },
  ['/sessions'] = { name = 'session', preset_args = { 'select' } },
  ['/share'] = { name = 'session', preset_args = { 'share' } },
  ['/timeline'] = { name = 'timeline' },
  ['/references'] = { name = 'references' },
  ['/undo'] = { name = 'undo' },
  ['/unshare'] = { name = 'session', preset_args = { 'unshare' } },
  ['/rename'] = { name = 'session', preset_args = { 'rename' } },
  ['/thinking'] = { name = 'toggle_reasoning_output' },
  ['/reasoning'] = { name = 'toggle_reasoning_output' },
  ['/review'] = { name = 'review' },
}

---@param preset OpencodeSlashPreset
---@return string
local function preset_to_command_string(preset)
  local parts = { preset.name }
  for _, arg in ipairs(preset.preset_args or {}) do
    table.insert(parts, arg)
  end
  return table.concat(parts, ' ')
end

---@return table<string, OpencodeSlashCommandSpec>
local function build_builtin_slash_command_definitions()
  local command_defs = commands.get_commands()
  local slash_defs = {}

  for slash_cmd, preset in pairs(slash_command_presets) do
    local cmd_str = preset_to_command_string(preset)
    local command_def = command_defs[preset.name]
    local desc = 'Run :Opencode ' .. cmd_str
    if command_def and command_def.desc then
      desc = command_def.desc
    end

    slash_defs[slash_cmd] = {
      command_name = preset.name,
      preset_args = vim.deepcopy(preset.preset_args or {}),
      -- Keep cmd_str for help/introspection and parseability checks, but execute via structured fields.
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

---@param command_name string
---@param args string[]|nil
---@return any
local function dispatch_parsed(command_name, args)
  local parsed = commands.build_parsed_intent(command_name, args or {})
  return commands.execute_parsed_intent(parsed)
end

---@param slash_cmd string
---@param def OpencodeSlashCommandSpec
---@return OpencodeSlashCommand|nil
local function to_runtime_slash_command(slash_cmd, def)
  local fn = def.fn
  if not fn and type(def.command_name) == 'string' then
    local command_name = def.command_name
    local preset_args = vim.deepcopy(def.preset_args or {})
    fn = function(args)
      local merged_args = vim.list_extend(vim.deepcopy(preset_args), args or {})
      return dispatch_parsed(command_name, merged_args)
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
          local cmd_args = vim.list_extend({ name }, args or {})
          return dispatch_parsed('command', cmd_args)
        end,
        args = true,
      })
    end
  end

  return result
end)

return M
