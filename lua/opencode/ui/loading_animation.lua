local state = require('opencode.state')
local config = require('opencode.config')

local Timer = require('opencode.ui.timer')
local M = {}

M._animation = {
  frames = nil,
  text = 'Thinking... ',
  status_data = nil,
  current_frame = 1,
  timer = nil,
  fps = 10,
  extmark_id = nil,
  ns_id = vim.api.nvim_create_namespace('opencode_loading_animation'),
  status_event_manager = nil,
}

---@param status table|nil
---@return string|nil
function M._format_status_text(status)
  if type(status) ~= 'table' then
    return nil
  end

  local status_type = status.type

  if status_type == 'busy' then
    return M._animation.text
  end

  if status_type == 'idle' then
    return nil
  end

  if status_type == 'retry' then
    local message = status.message or 'Retrying request'
    local details = {}

    if type(status.attempt) == 'number' then
      table.insert(details, 'retry ' .. status.attempt)
    end

    if type(status.next) == 'number' then
      local now_ms = os.time() * 1000
      local seconds = math.max(0, math.ceil((status.next - now_ms) / 1000))
      table.insert(details, 'in ' .. seconds .. 's')
    end

    if #details > 0 then
      return string.format('%s (%s)... ', message, table.concat(details, ', '))
    end

    return message .. '... '
  end

  if type(status.message) == 'string' and status.message ~= '' then
    return status.message .. '... '
  end

  return M._animation.text
end

local function unsubscribe_session_status_event(manager)
  -- No-op: disable session.status event subscription introduced recently.
  -- Reverting session.status handling to avoid interfering with existing
  -- behavior. This keeps the loading animation logic focused on job_count
  -- and user_message_count as before.
  return
end

local function subscribe_session_status_event(manager)
  -- No-op: do not subscribe to session.status events. See note in
  -- unsubscribe_session_status_event for rationale.
  return
end

local function is_active_session_busy()
  local active_session = state.active_session
  local session_id = active_session and active_session.id
  if session_id and ((state.user_message_count or {})[session_id] or 0) > 0 then
    return true
  end

  local ok, question_window = pcall(require, 'opencode.ui.question_window')
  if ok and question_window.has_question and question_window.belongs_to_active_session then
    local current_question = question_window._current_question
    if question_window.has_question() and question_window.belongs_to_active_session(current_question) then
      return true
    end
  end

  if M._animation.status_data and M._animation.status_data.type ~= 'idle' then
    return true
  end

  return state.jobs.is_running()
end

function M.on_session_status(properties)
  -- Disabled: Ignore session.status updates to keep loading animation
  -- behavior stable. Previously this updated status_data and triggered
  -- a render which caused regressions in some environments.
  return
end

local function on_active_session_change(_, new_session, old_session)
  local new_id = new_session and new_session.id
  local old_id = old_session and old_session.id
  if new_id ~= old_id then
    M._animation.status_data = nil
    if is_active_session_busy() then
      M.start(state.windows)
    else
      M.stop()
    end
  end
end

local function on_user_message_count_change()
  if not state.windows then
    return
  end

  if is_active_session_busy() then
    if not M.is_running() then
      M.start(state.windows)
    else
      M.render(state.windows)
    end
  else
    M.stop()
  end
end

local function on_event_manager_change(_, new_manager, old_manager)
  unsubscribe_session_status_event(old_manager)
  subscribe_session_status_event(new_manager)
end

function M._get_display_text()
  return M._format_status_text(M._animation.status_data) or M._animation.text
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

  if not is_active_session_busy() then
    M.stop()
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
      M.render(state.windows)
      if is_active_session_busy() then
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
  M._animation.status_data = nil
  if state.windows and state.windows.footer_buf and vim.api.nvim_buf_is_valid(state.windows.footer_buf) then
    pcall(vim.api.nvim_buf_clear_namespace, state.windows.footer_buf, M._animation.ns_id, 0, -1)
  end
end

function M.is_running()
  return M._animation.timer ~= nil
end

local function on_running_change(_, new_value)
  if not state.windows then
    return
  end

  if (new_value and new_value > 0) or is_active_session_busy() then
    if not M.is_running() then
      M.start(state.windows)
    else
      M.render(state.windows)
    end
  else
    M.stop()
  end
end

function M.setup()
  state.store.subscribe('job_count', on_running_change)
  state.store.subscribe('user_message_count', on_user_message_count_change)
  state.store.subscribe('active_session', on_active_session_change)
  if is_active_session_busy() then
    M.start(state.windows)
  else
    M.stop()
  end
end

function M.teardown()
  state.store.unsubscribe('job_count', on_running_change)
  state.store.unsubscribe('user_message_count', on_user_message_count_change)
  state.store.unsubscribe('active_session', on_active_session_change)
  M._animation.status_data = nil
end

return M
