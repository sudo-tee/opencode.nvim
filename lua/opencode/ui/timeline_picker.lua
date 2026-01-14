local M = {}
local config = require('opencode.config')
local api = require('opencode.api')
local base_picker = require('opencode.ui.base_picker')

---Format message parts for timeline picker
---@param msg OpencodeMessage Message object
---@return PickerItem
function format_message_item(msg, width)
  local preview = msg.parts and msg.parts[1] and msg.parts[1].text or ''

  local debug_text = 'ID: ' .. (msg.info.id or 'N/A')

  return base_picker.create_time_picker_item(vim.trim(preview), msg.info.time.created, debug_text, width)
end

function M.pick(messages, callback)
  local keymap = config.keymap.timeline_picker
  local actions = {
    undo = {
      key = keymap.undo,
      label = 'undo',
      fn = function(selected, opts)
        api.undo(selected.info.id)
      end,
      reload = false,
    },
    fork = {
      key = keymap.fork,
      label = 'fork',
      fn = function(selected, opts)
        api.fork_session(selected.info.id)
      end,
      reload = false,
    },
  }

  return base_picker.pick({
    items = messages,
    format_fn = format_message_item,
    actions = actions,
    callback = callback,
    title = 'Timeline',
    width = config.ui.picker_width or 100,
    layout_opts = config.ui.picker,
  })
end

return M
