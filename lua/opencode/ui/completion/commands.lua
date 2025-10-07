local M = {}

local function get_available_commands()
  local api = require('opencode.api')
  local commands = api.get_slash_commands()

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
end

---@type CompletionSource
local command_source = {
  name = 'commands',
  priority = 1,
  complete = function(context)
    local config = require('opencode.config').get()
    local input_text = vim.api.nvim_buf_get_lines(0, 0, -1, false)

    if not context.line:match('^' .. vim.pesc(context.trigger_char) .. '[^%s/]*$') then
      return {}
    end

    if context.trigger_char ~= config.keymap.window.slash_commands then
      return {}
    end

    local items = {}
    local input_lower = context.input:lower()
    local commands = get_available_commands()

    for _, command in ipairs(commands) do
      local name_lower = command.name:lower()
      local desc_lower = command.description:lower()

      if context.input == '' or name_lower:find(input_lower, 1, true) or desc_lower:find(input_lower, 1, true) then
        local item = {
          label = command.name .. (command.args and ' *' or ''),
          kind = 'command',
          detail = command.description,
          documentation = command.documentation .. (command.args and '\n\n* This command takes arguments.' or ''),
          insert_text = command.name,
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
  end,
  on_complete = function(item)
    if item.kind == 'command' then
      if item.data.fn then
        if item.data.args then
          require('opencode.ui.input_window').set_content(item.insert_text .. ' ')
          vim.api.nvim_win_set_cursor(0, { 1, #item.insert_text + 1 })
          return
        end
        item.data.fn()
        require('opencode.ui.input_window').set_content('')
      else
        vim.notify('Command not found: ' .. item.label, vim.log.levels.ERROR)
      end
    end
  end,
}

---Get the command completion source
---@return CompletionSource
function M.get_source()
  return command_source
end

return M
