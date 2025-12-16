local config = require('opencode.config')
local Timer = require('opencode.ui.timer')

---@class CursorSpinner
---@field buf integer
---@field row integer
---@field col integer
---@field ns_id integer
---@field extmark_id integer|nil
---@field current_frame integer
---@field timer Timer|nil
---@field active boolean
---@field frames string[]
local CursorSpinner = {}
CursorSpinner.__index = CursorSpinner

function CursorSpinner.new(buf, row, col)
  local self = setmetatable({}, CursorSpinner)
  self.buf = buf
  self.row = row
  self.col = col
  self.ns_id = vim.api.nvim_create_namespace('opencode_quick_chat_spinner')
  self.extmark_id = nil
  self.current_frame = 1
  self.timer = nil
  self.active = true

  self.frames = config.values.ui.loading_animation and config.values.ui.loading_animation.frames
    or { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

  self:render()
  self:start_timer()
  return self
end

function CursorSpinner:render()
  if not self.active or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  local frame = ' ' .. self.frames[self.current_frame]
  self.extmark_id = vim.api.nvim_buf_set_extmark(self.buf, self.ns_id, self.row, self.col, {
    id = self.extmark_id,
    virt_text = { { frame .. ' ', 'Comment' } },
    virt_text_pos = 'overlay',
    right_gravity = false,
  })
end

function CursorSpinner:next_frame()
  self.current_frame = (self.current_frame % #self.frames) + 1
end

function CursorSpinner:start_timer()
  self.timer = Timer.new({
    interval = 100, -- 10 FPS like the main loading animation
    on_tick = function()
      if not self.active then
        return false
      end
      self:next_frame()
      self:render()
      return true
    end,
    repeat_timer = true,
  })
  self.timer:start()
end

function CursorSpinner:stop()
  if not self.active then
    return
  end

  self.active = false

  if self.timer then
    self.timer:stop()
    self.timer = nil
  end

  if self.extmark_id and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_del_extmark, self.buf, self.ns_id, self.extmark_id)
  end
end

return CursorSpinner
