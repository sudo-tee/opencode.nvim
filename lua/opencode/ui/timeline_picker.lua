local M = {}
local config = require('opencode.config')
local commands = require('opencode.commands')
local base_picker = require('opencode.ui.base_picker')

---Format an Entry for the timeline picker.
---@param entry table
---@return PickerItem
local function format_message_item(entry, width)
  local preview = ''
  for _, content in ipairs(entry.content or {}) do
    if content.kind == 'text' and not content.synthetic and not content.ignored and type(content.text) == 'string' then
      preview = content.text
      break
    end
  end
  return base_picker.create_time_picker_item(
    vim.trim(preview),
    entry.time and entry.time.created,
    'ID: ' .. entry.id,
    width
  )
end

---@param name string
---@return fun(selected: table)
local function command_action(name)
  return function(selected)
    local parsed = commands.build_parsed_intent(name, { selected.id })
    commands.execute_parsed_intent(parsed)
  end
end

---@param messages table[]
---@param callback fun(entry: table|nil)
---@return boolean
function M.pick(messages, callback)
  local keymap = config.keymap.timeline_picker
  local actions = {
    undo = {
      key = keymap.undo,
      label = 'undo',
      fn = command_action('undo'),
      reload = false,
    },
    fork = {
      key = keymap.fork,
      label = 'fork',
      fn = command_action('fork_session'),
      reload = false,
    },
  }

  return base_picker.pick({
    items = messages,
    format_fn = format_message_item,
    actions = actions,
    callback = callback,
    title = 'Timeline',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
  })
end

return M
