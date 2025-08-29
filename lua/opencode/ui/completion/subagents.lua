local M = {}

-- Common subagent types that are typically available in opencode
local common_subagents = {
  {
    name = 'general',
    description = 'General-purpose agent for complex multi-step tasks',
    documentation = 'Use for researching complex questions, searching for code, and executing multi-step tasks when you need autonomous handling of complex workflows.',
  },
  {
    name = 'review',
    description = 'Code review agent for quality and best practices',
    documentation = 'Specialized agent for reviewing code quality, identifying potential issues, and suggesting improvements following best practices.',
  },
  {
    name = 'search',
    description = 'Search agent for finding code and files',
    documentation = 'Agent specialized in searching through codebases, finding relevant files, functions, and code patterns efficiently.',
  },
  {
    name = 'test',
    description = 'Testing agent for test generation and validation',
    documentation = 'Agent focused on creating, running, and validating tests for your codebase.',
  },
  {
    name = 'refactor',
    description = 'Refactoring agent for code improvement',
    documentation = 'Agent specialized in code refactoring, restructuring, and optimization while maintaining functionality.',
  },
  {
    name = 'debug',
    description = 'Debugging agent for issue analysis',
    documentation = 'Agent focused on analyzing bugs, tracing issues, and providing debugging assistance.',
  },
  on_complete = function(item)
    -- Called when a subagent completion is selected
    if item.data and item.data.subagent_type then
      vim.notify('Subagent selected: ' .. item.data.subagent_type, vim.log.levels.INFO)

      -- You could add more functionality here, like:
      -- - Logging subagent usage
      -- - Setting up environment for the specific subagent
      -- - Triggering specific subagent initialization
    end
  end,
}

---@type CompletionSource
local subagent_source = {
  name = 'subagents',
  complete = function(context)
    local config = require('opencode.config').get()
    if context.trigger_char ~= config.keymap.window.mention then
      return {}
    end

    local items = {}
    local input_lower = context.input:lower()

    for _, subagent in ipairs(common_subagents) do
      local name_lower = subagent.name:lower()
      local desc_lower = subagent.description:lower()

      -- Match if input is empty, or if name/description contains input
      if context.input == '' or name_lower:find(input_lower, 1, true) or desc_lower:find(input_lower, 1, true) then
        local item = {
          label = subagent.name .. ' (agent)',
          kind = 'subagent',
          detail = subagent.description,
          documentation = subagent.documentation,
          insert_text = subagent.name,
          source_name = 'subagents',
          data = {
            type = 'subagent',
            subagent_type = subagent.name,
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
    if item.data and item.data.subagent_type then
      local example = string.format(
        '%s\n\nExample usage:\n@%s "Analyze this function for performance issues"',
        item.documentation or '',
        item.data.subagent_type
      )
      item.documentation = example
    end
    return item
  end,
  on_complete = function(item)
    vim.print('⭕ ❱ subagents.lua:117 ❱ ƒ(anonymous) ❱ item =', item)
  end,
}

---Get the subagent completion source
---@return CompletionSource
function M.get_source()
  return subagent_source
end

---Add a custom subagent type
---@param name string Subagent name
---@param description string Short description
---@param documentation string|nil Optional detailed documentation
function M.add_subagent(name, description, documentation)
  table.insert(common_subagents, {
    name = name,
    description = description,
    documentation = documentation or description,
  })
end

return M
