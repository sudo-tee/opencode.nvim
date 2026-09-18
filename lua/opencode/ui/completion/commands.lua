local Promise = require('opencode.promise')
local config_file = require('opencode.config_file')
local slash_commands = require('opencode.slash_commands')
local M = {}

---@param execute_slash_command? fun(slash_cmd: string, args: string[]|nil): any
---@return CompletionSource
local function create_source(execute_slash_command)
  local get_available_commands = Promise.async(function()
    local results = {}
    for key, cmd_info in pairs(slash_commands.get_definitions()) do
      table.insert(results, {
        name = key,
        description = cmd_info.desc or ('Run :Opencode ' .. cmd_info.cmd_str),
        documentation = 'Opencode command: ' .. key,
        command_key = key,
        args = cmd_info.args,
        fn = execute_slash_command and function(args)
          return execute_slash_command(key, args)
        end,
      })
    end

    local user_commands = config_file.get_user_commands():await()
    for name, command in pairs(user_commands or {}) do
      table.insert(results, {
        name = '/' .. name,
        description = command.description or 'User command',
        documentation = 'Opencode command: /' .. name,
        command_key = name,
        args = true,
      })
    end

    return results
  end)

  local custom_kind = require('opencode.ui.completion.kind')

  return {
    name = 'commands',
    priority = 1,
    custom_kind = custom_kind.register('commands', require('opencode.ui.icons').get('command')),
    complete = Promise.async(function(context)
      local icons = require('opencode.ui.icons')
      if not context.line:match('^' .. vim.pesc(context.trigger_char) .. '[^%s/]*$') then
        return {}
      end

      local config = require('opencode.config')
      local expected_trigger = config.get_key_for_function('input_window', 'slash_commands')
      if context.trigger_char ~= expected_trigger then
        return {}
      end

      local items = {}
      local input_lower = context.input:lower()
      local commands = get_available_commands():await()

      for _, command in ipairs(commands) do
        local name_lower = command.name:lower()
        local desc_lower = command.description:lower()

        if context.input == '' or name_lower:find(input_lower, 1, true) or desc_lower:find(input_lower, 1, true) then
          table.insert(items, {
            label = command.name .. (command.args and ' *' or ''),
            kind = 'commands',
            kind_icon = icons.get('command'),
            detail = command.description,
            documentation = command.documentation .. (command.args and '\n\n* This command takes arguments.' or ''),
            insert_text = command.name:sub(2) .. (command.args and ' ' or ''),
            source_name = 'commands',
            data = {
              name = command.name,
              fn = command.fn,
              args = command.args,
            },
          })
        end
      end

      require('opencode.ui.completion.sort').sort_by_relevance(items, context.input)
      return items
    end),
    on_complete = function(item)
      if item.kind == 'commands' and item.data and item.data.fn and not item.data.args then
        vim.defer_fn(function()
          item.data.fn()
        end, 10)
        require('opencode.ui.input_window').set_content('')
      end
    end,
    get_trigger_character = function()
      local config = require('opencode.config')
      return config.get_key_for_function('input_window', 'slash_commands') or '/'
    end,
  }
end

---@param execute_slash_command? fun(slash_cmd: string, args: string[]|nil): any
---@return CompletionSource
function M.get_source(execute_slash_command)
  return create_source(execute_slash_command)
end

return M
