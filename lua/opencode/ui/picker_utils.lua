local config = require('opencode.config')
local util = require('opencode.util')
local M = {}

---@class PickerItem
---@field content string Main content text
---@field time_text? string Optional time text
---@field debug_text? string Optional debug text
---@field to_string fun(self: PickerItem): string
---@field to_formatted_text fun(self: PickerItem): string, table

---@param text? string
---@param width integer
---@param opts? {align?: "left" | "right" | "center", truncate?: boolean}
function M.align(text, width, opts)
  text = text or ''
  opts = opts or {}
  opts.align = opts.align or 'left'
  local tw = vim.api.nvim_strwidth(text)
  if tw > width then
    return opts.truncate and (vim.fn.strcharpart(text, 0, width - 1) .. '…') or text
  end
  local left = math.floor((width - tw) / 2)
  local right = width - tw - left
  if opts.align == 'left' then
    left, right = 0, width - tw
  elseif opts.align == 'right' then
    left, right = width - tw, 0
  end
  return (' '):rep(left) .. text .. (' '):rep(right)
end

---Creates a generic picker item that can format itself for different pickers
---@param text string Array of text parts to join
---@param time? number Optional time text to highlight
---@param debug_text? string Optional debug text to append
---@return PickerItem
function M.create_picker_item(text, time, debug_text)
  local debug_offset = config.debug.show_ids and #debug_text or 0
  local item = {
    content = M.align(text, 70 - debug_offset + 1, { truncate = true }),
    time_text = time and M.align(util.format_time(time), 20, { align = 'right' }),
    debug_text = config.debug.show_ids and debug_text or nil,
  }

  function item:to_string()
    local segments = { self.content }

    if self.time_text then
      table.insert(segments, self.time_text)
    end

    if self.debug_text then
      table.insert(segments, self.debug_text)
    end

    return table.concat(segments, ' ')
  end

  function item:to_formatted_text()
    local segments = { { self.content } }

    if self.time_text then
      table.insert(segments, { ' ' .. self.time_text, 'OpencodePickerTime' })
    end

    if self.debug_text then
      table.insert(segments, { ' ' .. self.debug_text, 'OpencodeDebugText' })
    end

    return segments
  end

  return item
end

return M
