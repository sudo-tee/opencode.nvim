local Promise = require('opencode.promise')
local M = {}

local get_available_commands = Promise.async(function()
  local api = require('opencode.api')
  local commands = api.get_slash_commands():await()

  local results = {}
  for key, cmd_info in ipairs(commands) do
    table.insert(results, {
      name = cmd_info.slash_cmd,
      description = cmd_info.desc,
      documentation = 'Opencode command: ' .. cmd_info.slash_cmd,
      command_key = key,
      args = cmd_info.args,
      fn = cmd_info.fn,
    })
  end

  return results
end)

local custom_kind = require('opencode.ui.completion.kind')

---@type CompletionSource
local command_source = {
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
        local item = {
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
        }

        table.insert(items, item)
      end
    end

    local sort_util = require('opencode.ui.completion.sort')
    sort_util.sort_by_relevance(items, context.input)

    return items
  end),
  on_complete = function(item)
    if item.kind == 'commands' then
      if item.data.fn then
        if item.data.args then
          return
        end
        vim.defer_fn(function()
          item.data.fn()
        end, 10) -- slight delay to allow completion menu to close,
        require('opencode.ui.input_window').set_content('')
      else
        vim.notify('Command not found: ' .. item.label, vim.log.levels.ERROR)
      end
    end
  end,
  get_trigger_character = function()
    local config = require('opencode.config')
    return config.get_key_for_function('input_window', 'slash_commands') or '/'
  end,
}

---Get the command completion source
---@return CompletionSource
function M.get_source()
  return command_source
end

return M
