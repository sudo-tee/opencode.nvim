local M = {}

-- Extract command information from the API
local function get_available_commands()
  local api = require('opencode.api')
  local commands = {}

  -- Extract commands from the API commands table
  for key, cmd_info in pairs(api.commands) do
    if cmd_info.slash_cmd then
      table.insert(commands, {
        name = cmd_info.slash_cmd,
        description = cmd_info.desc or 'Opencode command',
        documentation = cmd_info.desc or 'Opencode command: ' .. key,
        command_key = key,
      })
    end
  end

  -- Add common slash commands that might not be in the commands table
  local common_commands = {
    {
      name = '/help',
      description = 'Show help information',
      documentation = 'Display help information about available commands and usage.',
    },
    {
      name = '/clear',
      description = 'Clear the current session',
      documentation = 'Clear the current conversation session and start fresh.',
    },
    {
      name = '/quit',
      description = 'Quit opencode',
      documentation = 'Exit the opencode interface and return to normal editing.',
    },
    {
      name = '/exit',
      description = 'Exit opencode',
      documentation = 'Exit the opencode interface and return to normal editing.',
    },
  }

  -- Add common commands if they don't already exist
  local existing_names = {}
  for _, cmd in ipairs(commands) do
    existing_names[cmd.name] = true
  end

  for _, cmd in ipairs(common_commands) do
    if not existing_names[cmd.name] then
      table.insert(commands, cmd)
    end
  end

  return commands
end

---@type CompletionSource
local command_source = {
  name = 'commands',
  complete = function(context)
    local config = require('opencode.config').get()
    local input_text = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    if #input_text > 1 or context.line ~= context.trigger_char then
      return {}
    end

    if context.trigger_char ~= config.keymap.window.slash_commands then
      return {}
    end

    local items = {}
    local input_lower = context.input:lower()
    local commands = get_available_commands()

    -- Filter commands based on input
    for _, command in ipairs(commands) do
      local name_lower = command.name:lower()
      local desc_lower = command.description:lower()

      -- Match if input is empty, or if name/description contains input
      if context.input == '' or name_lower:find(input_lower, 1, true) or desc_lower:find(input_lower, 1, true) then
        local item = {
          label = command.name,
          kind = 'command',
          detail = command.description,
          documentation = command.documentation,
          insert_text = command.name,
          source_name = 'commands', -- Add source name
          data = {
            type = 'command',
            command_key = command.command_key,
          },
        }

        table.insert(items, item)
      end
    end

    -- Sort by relevance
    table.sort(items, function(a, b)
      local a_name = a.label:lower()
      local b_name = b.label:lower()

      -- Exact matches first
      local a_exact = a_name == input_lower
      local b_exact = b_name == input_lower
      if a_exact ~= b_exact then
        return a_exact
      end

      -- Then starts with input
      local a_starts = a_name:find('^' .. vim.pesc(input_lower))
      local b_starts = b_name:find('^' .. vim.pesc(input_lower))
      if a_starts ~= b_starts then
        return a_starts ~= nil
      end

      -- Then alphabetical
      return a_name < b_name
    end)

    return items
  end,
  resolve = function(item)
    -- Add usage example to documentation
    if item.data and item.data.type == 'command' then
      local example = string.format('%s\n\nUsage:\n%s', item.documentation or '', item.label)
      item.documentation = example
    end
    return item
  end,
  on_complete = function(item)
    vim.print('⭕ ❱ commands.lua:125 ❱ ƒ(anonymous) ❱ item =', item)
    -- Called when a command completion is selected
    if item.data and item.data.type == 'command' then
      vim.notify('Command selected: ' .. item.label, vim.log.levels.INFO)

      -- You could add more functionality here, like:
      -- - Executing the command immediately
      -- - Logging command usage
      -- - Setting up command-specific environment

      if item.data.command_key then
        -- Maybe trigger the actual command
        -- local api = require('opencode.api')
        -- api.execute_command(item.data.command_key)
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
