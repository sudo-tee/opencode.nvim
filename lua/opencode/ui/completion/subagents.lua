local icons = require('opencode.ui.icons')
local M = {}

---@type CompletionSource
local subagent_source = {
  name = 'subagents',
  priority = 1,
  complete = function(context)
    local subagents = require('opencode.config_file').get_subagents()
    local config = require('opencode.config')
    local config_mod = require('opencode.config')
    local expected_trigger = config_mod.get_key_for_function('input_window', 'mention')
    if context.trigger_char ~= expected_trigger then
      return {}
    end

    local items = {}
    local input_lower = context.input:lower()

    for _, subagent in ipairs(subagents) do
      local name_lower = subagent:lower()

      if context.input == '' or name_lower:find(input_lower, 1, true) then
        local item = {
          label = subagent .. ' (agent)',
          kind = 'subagent',
          kind_icon = icons.get('agent'),
          detail = 'Subagent',
          documentation = 'Use the "' .. subagent .. '" subagent for this task.',
          insert_text = subagent,
          source_name = 'subagents',
          data = {
            name = subagent,
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
    local state = require('opencode.state')
    local context = require('opencode.context')
    local mention = require('opencode.ui.mention')
    mention.highlight_all_mentions(state.windows.input_buf)
    context.add_subagent(item.data.name)
  end,
}

---Get the subagent completion source
---@return CompletionSource
function M.get_source()
  return subagent_source
end

return M
