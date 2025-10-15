local state = require('opencode.state')
local config = require('opencode.config')

local Timer = require('opencode.ui.timer')
local M = {}

M._animation = {
  frames = nil,
  text = 'Thinking... ',
  current_frame = 1,
  timer = nil,
  fps = 10,
  extmark_id = nil,
  ns_id = vim.api.nvim_create_namespace('opencode_loading_animation'),
}

function M._get_frames()
  if M._animation.frames then
    return M._animation.frames
  end
  local ui_config = config.ui
  if ui_config and ui_config.loading_animation and ui_config.loading_animation.frames then
    return ui_config.loading_animation.frames
  end
  return { '·', '․', '•', '∙', '●', '⬤', '●', '∙', '•', '․' }
end

M.render = vim.schedule_wrap(function(windows)
  windows = windows or state.windows
  if not windows or not windows.output_buf or not windows.footer_buf then
    return false
  end

  if not vim.api.nvim_buf_is_valid(windows.output_buf) or not vim.api.nvim_buf_is_valid(windows.footer_buf) then
    return false
  end

  if not state.is_running() then
    M.stop()
    return false
  end

  local loading_text = M._animation.text .. M._get_frames()[M._animation.current_frame]

  M._animation.extmark_id = vim.api.nvim_buf_set_extmark(windows.footer_buf, M._animation.ns_id, 0, 0, {
    id = M._animation.extmark_id or nil,
    virt_text = { { loading_text, 'OpenCodeHint' } },
    virt_text_pos = 'overlay',
    hl_mode = 'replace',
  })

  return true
end)

function M._next_frame()
  return (M._animation.current_frame % #M._get_frames()) + 1
end

function M._start_animation_timer(windows)
  M._clear_animation_timer()

  local interval = math.floor(1000 / M._animation.fps)
  M._animation.timer = Timer.new({
    interval = interval,
    on_tick = function()
      M._animation.current_frame = M._next_frame()
      M.render(state.windows)
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
  windows = windows or state.windows
  if not windows then
    return
  end
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

local function on_running_change(_, new_value)
  if not state.windows then
    return
  end

  if not M.is_running() and new_value and new_value > 0 then
    M.start(state.windows)
  else
    M.stop()
  end
end

function M.setup()
  state.subscribe('job_count', on_running_change)
end

function M.teardown()
  state.unsubscribe('job_count', on_running_change)
end

return M
