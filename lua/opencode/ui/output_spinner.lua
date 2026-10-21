local config = require('opencode.config')
local Timer = require('opencode.ui.timer')

-- Ticks rewrite only extmark virt_text, so buffer lines and renderer caches stay untouched.
local M = {}

M.namespace = vim.api.nvim_create_namespace('opencode_output_spinner')

local INTERVAL_MS = 100

---@class OutputSpinnerMark
---@field opts vim.api.keyset.set_extmark
---@field virt_text [string, string][]
---@field frame_chunk integer Index of the `virt_text` chunk that shows the frame

---@type table<integer, table<integer, OutputSpinnerMark>>
local marks_by_buf = {}
local current_frame = 1
---@type Timer|nil
local timer

---@return string[]
local function frames()
  return config.ui.loading_animation.frames
end

---@return string
function M.frame()
  local list = frames()
  return list[(current_frame - 1) % #list + 1] --[[@as string]]
end

---@param mark OutputSpinnerMark
---@return vim.api.keyset.set_extmark
local function with_frame(mark)
  local opts = vim.deepcopy(mark.opts)
  local virt_text = vim.deepcopy(mark.virt_text)
  local chunk = virt_text[mark.frame_chunk] --[[@as [string, string] ]]
  chunk[1] = M.frame()
  opts.virt_text = virt_text
  return opts
end

---@param buf integer
---@param marks table<integer, OutputSpinnerMark>
---@return boolean alive Whether the buffer still has spinner extmarks
local function animate_buffer(buf, marks)
  if not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local present = {}
  for _, extmark in ipairs(vim.api.nvim_buf_get_extmarks(buf, M.namespace, 0, -1, {})) do
    local id, row, col = extmark[1], extmark[2], extmark[3]
    local mark = marks[id] --[[@as OutputSpinnerMark?]]
    if mark then
      present[id] = true
      local opts = with_frame(mark)
      opts.id = id
      pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, row, col, opts)
    end
  end
  for id in pairs(marks) do
    if not present[id] then
      marks[id] = nil
    end
  end
  return next(marks) ~= nil
end

local function tick()
  current_frame = current_frame % #frames() + 1
  for buf, marks in pairs(marks_by_buf) do
    if not animate_buffer(buf, marks) then
      marks_by_buf[buf] = nil
    end
  end
  if next(marks_by_buf) == nil then
    timer = nil
    return false
  end
  return true
end

local function ensure_timer()
  if timer and timer:is_running() then
    return
  end
  timer = Timer.new({ interval = INTERVAL_MS, on_tick = tick, repeat_timer = true })
  timer:start()
end

---@param buf integer
---@param row integer 0-based
---@param col integer 0-based
---@param opts vim.api.keyset.set_extmark Must carry `virt_text`
---@param frame_chunk integer
function M.place(buf, row, col, opts, frame_chunk)
  local mark = {
    opts = opts,
    virt_text = opts.virt_text --[[@as [string, string][] ]],
    frame_chunk = frame_chunk,
  }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, buf, M.namespace, row, col, with_frame(mark))
  if not ok then
    return
  end
  marks_by_buf[buf] = marks_by_buf[buf] or {}
  marks_by_buf[buf][id] = mark
  ensure_timer()
end

---@return boolean
function M.is_running()
  return timer ~= nil and timer:is_running()
end

function M.stop()
  if timer then
    timer:stop()
    timer = nil
  end
  marks_by_buf = {}
end

return M
