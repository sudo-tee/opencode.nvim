local icons = require('opencode.ui.icons')
local Promise = require('opencode.promise')

local M = {}

local custom_kind = require('opencode.ui.completion.kind')

---@type CompletionSource
local skill_source = {
  name = 'skills',
  priority = 1,
  custom_kind = custom_kind.register('skills', icons.get('skill')),
  complete = Promise.async(function(context)
    local config = require('opencode.config')
    local expected_trigger = config.get_key_for_function('input_window', 'slash_commands') or '/'
    if context.trigger_char ~= expected_trigger then
      return {}
    end

    if not context.line:match('^' .. vim.pesc(expected_trigger) .. '[^%s/]*$') then
      return {}
    end

    local state = require('opencode.state')
    local api_client = state and state.api_client
    if not api_client then
      return {}
    end

    local ok, skills = pcall(function()
      return api_client:list_skills():await()
    end)
    if not ok or not skills then
      return {}
    end
    ---@cast skills OpencodeSkill[]

    local items = {}

    for _, skill in ipairs(skills) do
      local item = {
        label = expected_trigger .. skill.name,
        kind = 'skill',
        kind_icon = icons.get('skill'),
        detail = skill.description or '',
        insert_text = skill.name .. ' ',
        source_name = 'skills',
        data = {
          name = skill.name,
          content = skill.content,
        },
      }
      table.insert(items, item)
    end

    local sort_util = require('opencode.ui.completion.sort')
    sort_util.sort_by_relevance(items, context.input)

    return items
  end),
  on_complete = function(item)
    if item.kind ~= 'skill' or not item.data or not item.data.content then
      return
    end

    vim.defer_fn(function()
      require('opencode.services.session_runtime').open({ new_session = false, focus = 'output' }):and_then(function()
        return require('opencode.services.messaging').send_message(item.data.content, {})
      end)
    end, 10)
    require('opencode.ui.input_window').set_content('')
  end,
  get_trigger_character = function()
    local config = require('opencode.config')
    return config.get_key_for_function('input_window', 'slash_commands') or '/'
  end,
}

---Get the skill completion source
---@return CompletionSource
function M.get_source()
  return skill_source
end

return M
