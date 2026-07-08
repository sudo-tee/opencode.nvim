local M = {}
local config = require('opencode.config')
local api = require('opencode.api')
local base_picker = require('opencode.ui.base_picker')

---@class OpencodeTimelinePickerOpts
---@field title? string Picker title (defaults to 'Timeline')
---@field callback fun(msg: OpencodeMessage|nil) Invoked with the selected message

---Format message parts for timeline picker
---@param msg OpencodeMessage Message object
---@param width number
---@return PickerItem
local function format_message_item(msg, width)
  local preview = msg.parts and msg.parts[1] and msg.parts[1].text or ''

  local debug_text = 'ID: ' .. (msg.info.id or 'N/A')

  return base_picker.create_time_picker_item(vim.trim(preview), msg.info.time.created, debug_text, width)
end

---Open a picker over the given user messages. The shared undo/fork actions
---always operate on the selected message via the server APIs; the caller
---decides what to do on plain selection by passing `opts.callback`.
---@param messages OpencodeMessage[]
---@param opts OpencodeTimelinePickerOpts
function M.pick(messages, opts)
  local keymap = config.keymap.timeline_picker
  local actions = {
    undo = {
      key = keymap.undo,
      label = 'undo',
      fn = function(selected, _opts)
        api.undo(selected.info.id)
      end,
      reload = false,
    },
    fork = {
      key = keymap.fork,
      label = 'fork',
      fn = function(selected, _opts)
        api.fork_session(selected.info.id)
      end,
      reload = false,
    },
  }

  return base_picker.pick({
    items = messages,
    format_fn = format_message_item,
    actions = actions,
    callback = opts.callback,
    title = opts.title or 'Timeline',
    width = config.ui.picker_width,
    layout_opts = config.ui.picker,
  })
end

return M
