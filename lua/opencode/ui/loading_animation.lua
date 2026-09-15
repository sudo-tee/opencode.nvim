local state = require('opencode.state')
local config = require('opencode.config')

local Timer = require('opencode.ui.timer')
local M = {}

M._animation = {
  frames = nil,
  text = 'Thinking... ',
  execution = nil,
  session_id = nil,
  current_frame = 1,
  timer = nil,
  fps = 10,
  extmark_id = nil,
  ns_id = vim.api.nvim_create_namespace('opencode_loading_animation'),
  unsubscribe = nil,
}

---@param execution table|nil
---@return string|nil
function M._format_execution_text(execution)
  if type(execution) ~= 'table' then
    return nil
  end

  if execution.activity == 'running' then
    return M._animation.text
  end

  if execution.activity ~= 'retrying' then
    return nil
  end

  local retry = execution.retry or {}
  local message = retry.message
    or (type(retry.error) == 'table' and retry.error.message)
    or 'Retrying request'
  local details = {}
  if type(retry.attempt) == 'number' then
    table.insert(details, 'retry ' .. retry.attempt)
  end
  if type(retry.scheduled_at) == 'number' then
    local now_ms = os.time() * 1000
    local seconds = math.max(0, math.ceil((retry.scheduled_at - now_ms) / 1000))
    table.insert(details, 'in ' .. seconds .. 's')
  end
  if #details > 0 then
    return string.format('%s (%s)... ', message, table.concat(details, ', '))
  end
  return message .. '... '
end

local function release_observation()
  if M._animation.unsubscribe then
    M._animation.unsubscribe()
    M._animation.unsubscribe = nil
  end
end

local function read_execution(observation)
  local observed = observation:read()
  M._animation.execution = observed.execution
  M._animation.session_id = observed.session and observed.session.id or nil
  M.refresh()
  M.render(state.windows)
end

M._on_active_session_change = function()
  release_observation()
  M._animation.execution = nil
  M._animation.session_id = nil
  local observation = state.session.active_observation()
  if observation then
    M._animation.unsubscribe = observation:watch({ 'execution' }, read_execution)
    read_execution(observation)
  else
    M.refresh()
    M.render(state.windows)
  end
end

function M._get_display_text()
  return M._format_execution_text(M._animation.execution) or M._animation.text
end

function M._get_frames()
  if M._animation.frames then
    return M._animation.frames
  end
  local ui_config = config.ui
  if ui_config and ui_config.loading_animation and ui_config.loading_animation.frames then
    return ui_config.loading_animation.frames
  end
  -- return { '·', '․', '•', '∙', '●', '⬤', '●', '∙', '•', '․' }
  return { '⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏' }
end

M.render = vim.schedule_wrap(function(windows)
  windows = windows or state.windows
  if not windows or not windows.output_buf or not windows.footer_buf then
    return false
  end

  if not vim.api.nvim_buf_is_valid(windows.output_buf) or not vim.api.nvim_buf_is_valid(windows.footer_buf) then
    return false
  end

  M.refresh()

  if not M.is_running() then
    return false
  end

  local loading_text = M._get_display_text() .. M._get_frames()[M._animation.current_frame]

  M._animation.extmark_id = vim.api.nvim_buf_set_extmark(windows.footer_buf, M._animation.ns_id, 0, 0, {
    id = M._animation.extmark_id or nil,
    virt_text = { { loading_text, 'OpencodeHint' } },
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
      M.render(windows)
      if M._should_animate() then
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
  if state.windows and state.windows.footer_buf and vim.api.nvim_buf_is_valid(state.windows.footer_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, state.windows.footer_buf, M._animation.ns_id, 0, -1)
  end
end

function M._should_animate()
  local execution = M._animation.execution
  if not execution or (execution.activity ~= 'running' and execution.activity ~= 'retrying') then
    return false
  end
  local active_session = state.active_session
  if not active_session then
    return false
  end
  return M._animation.session_id == active_session.id
end

function M.is_running()
  return M._animation.timer ~= nil
end

function M.refresh()
  if not state.windows then
    return
  end
  if M._should_animate() then
    if not M.is_running() then
      M.start(state.windows)
    end
  elseif M.is_running() then
    M.stop()
  end
end

function M.setup()
  state.store.subscribe('active_session', M._on_active_session_change)
  M._on_active_session_change()
end

function M.teardown()
  state.store.unsubscribe('active_session', M._on_active_session_change)
  release_observation()
  M._animation.execution = nil
  M._animation.session_id = nil
  M._clear_animation_timer()
end

return M
