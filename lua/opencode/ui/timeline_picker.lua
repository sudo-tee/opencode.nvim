local M = {}
local config = require('opencode.config')
local api = require('opencode.api')
local base_picker = require('opencode.ui.base_picker')

---Format message parts for timeline picker
---@param msg OpencodeMessage Message object
---@param width? number
---@param max_tw? number Pre-computed max time column width
---@return PickerItem
local function format_message_item(msg, width, max_tw)
  local preview = msg.parts and msg.parts[1] and msg.parts[1].text or ''

  local debug_text = 'ID: ' .. (msg.info.id or 'N/A')

  return base_picker.create_time_picker_item(vim.trim(preview), msg.info.time.created, debug_text, width, max_tw)
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

  local max_tw = base_picker.max_time_width(messages, function(msg)
    return msg.info and msg.info.time and msg.info.time.created
  end)

  return base_picker.pick({
    items = messages,
    format_fn = function(msg, width)
      return format_message_item(msg, width, max_tw)
    end,
    actions = actions,
    callback = callback,
    title = 'Timeline',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
  })
end

return M
