local config = require('opencode.config')
local Timer = require('opencode.ui.timer')

---@class Timer
---@field start function
---@field stop function
---@field is_running function

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
---@field float_win integer|nil
---@field float_buf integer|nil
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
  self.float_win = nil
  self.float_buf = nil

  self.frames = config.ui.loading_animation and config.ui.loading_animation.frames
    or { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }

  self:create_float()
  self:render()
  self:start_timer()
  return self
end

function CursorSpinner:create_float()
  if not self.active or not vim.api.nvim_buf_is_valid(self.buf) then
    return
  end

  self.float_buf = vim.api.nvim_create_buf(false, true)

  local win_config = self:get_float_config()

  self.float_win = vim.api.nvim_open_win(self.float_buf, false, win_config)

  vim.api.nvim_set_option_value('winhl', 'Normal:Comment', { win = self.float_win })
  vim.api.nvim_set_option_value('wrap', false, { win = self.float_win })
end

function CursorSpinner:get_float_config()
  return {
    relative = 'cursor',
    width = 3,
    height = 1,
    row = 0,
    col = 2, -- 2 columns to the right of cursor
    style = 'minimal',
    border = 'rounded',
    focusable = false,
    zindex = 1000,
  }
end

function CursorSpinner:render()
  if not self.active or not self.float_buf or not vim.api.nvim_buf_is_valid(self.float_buf) then
    return
  end

  local frame = ' ' .. self.frames[self.current_frame] .. ' '
  vim.api.nvim_buf_set_lines(self.float_buf, 0, -1, false, { frame })
end

function CursorSpinner:next_frame()
  self.current_frame = (self.current_frame % #self.frames) + 1
end

function CursorSpinner:start_timer()
  self.timer = Timer.new({
    interval = 100, -- 10 FPS
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

  if self.float_win and vim.api.nvim_win_is_valid(self.float_win) then
    pcall(vim.api.nvim_win_close, self.float_win, true)
  end

  if self.float_buf and vim.api.nvim_buf_is_valid(self.float_buf) then
    pcall(vim.api.nvim_buf_delete, self.float_buf, { force = true })
  end

  if self.extmark_id and vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_del_extmark, self.buf, self.ns_id, self.extmark_id)
  end
end

return CursorSpinner
