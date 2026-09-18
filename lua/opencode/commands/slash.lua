local Promise = require('opencode.promise')
local config = require('opencode.config')
local config_file = require('opencode.config_file')
local commands = require('opencode.commands')
local log = require('opencode.log')
local slash_commands = require('opencode.slash_commands')

local M = {}

---@return table<string, OpencodeSlashCommandSpec>
local function build_builtin_slash_command_definitions()
  local command_defs = commands.get_commands()
  local slash_defs = {}

  for slash_cmd, preset in pairs(slash_commands.get_definitions()) do
    local cmd_str = preset.cmd_str
    local command_def = command_defs[preset.command_name]
    local desc = 'Run :Opencode ' .. cmd_str
    if command_def and command_def.desc then
      desc = command_def.desc
    end

    slash_defs[slash_cmd] = {
      command_name = preset.command_name,
      preset_args = vim.deepcopy(preset.preset_args or {}),
      -- Keep cmd_str for help/introspection and parseability checks, but execute via structured fields.
      cmd_str = cmd_str,
      desc = desc,
      args = command_def and command_def.nargs ~= nil or preset.args or false,
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

function M.execute_builtin(slash_cmd, args)
  local def = M.get_builtin_command_definitions()[slash_cmd]
  if not def then
    return
  end
  local command = to_runtime_slash_command(slash_cmd, def)
  return command and command.fn(args)
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

  local state = require('opencode.state')
  local ok, skills = pcall(function()
    local connection = assert(state.opencode_server, 'Connection is not ready')
    local util = require('opencode.util')
    return connection.operations
      .list_skills(
        connection,
        { directory = state.current_cwd or vim.fn.getcwd() },
        util.apply_path_map,
        util.apply_reverse_path_map
      )
      :await()
  end)
  if ok and skills then
    for _, skill in ipairs(skills) do
      local skill_content = skill.content
      table.insert(result, {
        slash_cmd = '/' .. skill.name,
        desc = skill.description or 'Skill',
        fn = function(args)
          local message = skill_content
          if args and #args > 0 then
            message = skill_content .. '\n\n' .. table.concat(args, ' ')
          end
          require('opencode.services.session_runtime')
            .open({ new_session = false, focus = 'output' })
            :and_then(function()
              return require('opencode.services.messaging').send_message(message, {})
            end)
        end,
        args = true,
      })
    end
  end

  return result
end)

---@param command string
---@return OpencodeSlashCommand|nil
---@return string[]|nil
function M.resolve_input(command)
  local slash_commands = M.get_commands():await()
  local key = config.get_key_for_function('input_window', 'slash_commands') or '/'

  local cmd = command:sub(2):match('^%s*(.-)%s*$')
  if cmd == '' then
    return
  end
  local parts = vim.split(cmd, ' ')

  local command_cfg = vim.tbl_filter(function(c)
    return c.slash_cmd == key .. parts[1]
  end, slash_commands)[1]

  if command_cfg then
    local args = #parts > 1 and vim.list_slice(parts, 2) or nil
    return command_cfg, args
  else
    vim.notify('Unknown command: ' .. cmd, vim.log.levels.WARN)
  end
end

return M
