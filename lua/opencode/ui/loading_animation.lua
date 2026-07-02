local state = require('opencode.state')
local config = require('opencode.config')

local Timer = require('opencode.ui.timer')
local M = {}

M._animation = {
  frames = nil,
  text = 'Thinking... ',
  status_data = nil,
  status_session_id = nil,
  current_frame = 1,
  timer = nil,
  fps = 10,
  extmark_id = nil,
  ns_id = vim.api.nvim_create_namespace('opencode_loading_animation'),
  status_event_manager = nil,
  last_status_map = {},
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
  if manager and M._animation.status_event_manager == manager then
    manager:unsubscribe('session.status', M.on_session_status)
    M._animation.status_event_manager = nil
  end
end

local function subscribe_session_status_event(manager)
  if not manager then
    return
  end

  if M._animation.status_event_manager and M._animation.status_event_manager ~= manager then
    unsubscribe_session_status_event(M._animation.status_event_manager)
  end

  if M._animation.status_event_manager == manager then
    return
  end

  manager:subscribe('session.status', M.on_session_status)
  M._animation.status_event_manager = manager
end

function M.on_session_status(properties)
  if not properties or type(properties) ~= 'table' then
    return
  end

  if not properties.sessionID or not properties.status then
    return
  end

  M._animation.last_status_map[properties.sessionID] = properties.status

  local active_session = state.active_session
  if active_session and active_session.id == properties.sessionID then
    M._animation.status_data = properties.status
    M._animation.status_session_id = properties.sessionID
    M.refresh()
  end
  M.render(state.windows)
end

local function replay_status_for(session_id)
  local status = M._animation.last_status_map[session_id]
  if not status then
    return
  end
  local active_session = state.active_session
  if not active_session or active_session.id ~= session_id then
    return
  end
  M._animation.status_data = status
  M._animation.status_session_id = session_id
  M.refresh()
  M.render(state.windows)
end

M._on_active_session_change = function(_, new_session, old_session)
  local new_id = new_session and new_session.id
  local old_id = old_session and old_session.id
  if old_id and old_id ~= new_id then
    M._animation.status_data = nil
    M._animation.status_session_id = nil
  end
  if new_id then
    replay_status_for(new_id)
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
  local status = M._animation.status_data
  if not status or status.type == 'idle' then
    return false
  end
  local active_session = state.active_session
  if not active_session then
    return false
  end
  return M._animation.status_session_id == active_session.id
end

function M.sync_from_server()
  local api_client = state.api_client
  if not api_client or not api_client.list_session_status then
    return
  end

  api_client
    :list_session_status(state.current_cwd or vim.fn.getcwd())
    :and_then(function(status_map)
      if type(status_map) ~= 'table' then
        return
      end
      for session_id, status in pairs(status_map) do
        if not M._animation.last_status_map[session_id] then
          M._animation.last_status_map[session_id] = status
        end
      end
      local active_session = state.active_session
      if active_session then
        replay_status_for(active_session.id)
      end
    end)
    :catch(function(err)
      require('opencode.log').debug('loading_animation.sync_from_server failed: %s', tostring(err))
    end)
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
  state.store.subscribe('job_count', M.refresh)
  state.store.subscribe('active_session', M._on_active_session_change)
  state.store.subscribe('event_manager', on_event_manager_change)
  subscribe_session_status_event(state.event_manager)
  M.sync_from_server()
end

function M.teardown()
  state.store.unsubscribe('job_count', M.refresh)
  state.store.unsubscribe('active_session', M._on_active_session_change)
  state.store.unsubscribe('event_manager', on_event_manager_change)
  unsubscribe_session_status_event(M._animation.status_event_manager)
  M._animation.last_status_map = {}
  M._animation.status_data = nil
  M._animation.status_session_id = nil
  M._clear_animation_timer()
end

return M
