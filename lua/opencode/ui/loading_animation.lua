local state = require('opencode.state')

local Timer = require('opencode.ui.timer')
local M = {}

M._animation = {
  frames = { '·', '․', '•', '∙', '●', '⬤', '●', '∙', '•', '․' },
  text = 'Thinking... ',
  current_frame = 1,
  timer = nil,
  fps = 10,
  extmark_id = nil,
  ns_id = vim.api.nvim_create_namespace('opencode_loading_animation'),
}

M.render = vim.schedule_wrap(function(windows)
  if not windows.footer_buf and not windows.output_buf or not vim.api.nvim_buf_is_valid(windows.output_buf) then
    return false
  end

  local buffer_line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  if buffer_line_count <= 0 then
    return false
  end

  if not state.is_running() then
    M.stop()
    return false
  end

  local loading_text = M._animation.text .. M._animation.frames[M._animation.current_frame]

  M._animation.extmark_id = vim.api.nvim_buf_set_extmark(windows.footer_buf, M._animation.ns_id, 0, 0, {
    id = M._animation.extmark_id or nil,
    virt_text = { { loading_text, 'OpenCodeHint' } },
    virt_text_pos = 'overlay',
    hl_mode = 'replace',
  })

  return true
end)

function M._next_frame()
  return (M._animation.current_frame % #M._animation.frames) + 1
end

function M._start_animation_timer(windows)
  M._clear_animation_timer()

  local interval = math.floor(1000 / M._animation.fps)
  M._animation.timer = Timer.new({
    interval = interval,
    on_tick = function()
      M._animation.current_frame = M._next_frame()
      M.render(windows)
      if state.is_running() then
        return true
      else
        M.stop()
        return false
      end
    end,
    repeat_timer = true,
  })
  M._animation.timer:start()
end

function M._clear_animation_timer()
  if M._animation.timer then
    M._animation.timer:stop()
    M._animation.timer = nil
  end
end

function M.start(windows)
  M._start_animation_timer(windows)
  M.render(windows)
end

function M.stop()
  M._clear_animation_timer()
  M._animation.current_frame = 1
  if state.windows and state.windows.footer_buf then
    vim.api.nvim_buf_clear_namespace(state.windows.footer_buf, M._animation.ns_id, 0, -1)
  end
end

function M.is_running()
  return M._animation.timer ~= nil
end

return M
