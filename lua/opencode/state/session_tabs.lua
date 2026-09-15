local store = require('opencode.state.store')

---@class OpencodeSessionTabRuntime
---@field id string Logical panel-tab identifier
---@field active_session Session|nil
---@field windows OpencodeWindowState|nil Buffers and the currently mounted panel windows
---@field is_opening boolean
---@field input_content table
---@field is_opencode_focused boolean
---@field last_focused_opencode_window string|nil
---@field last_input_window_position integer[]|nil
---@field last_output_window_position integer[]|nil
---@field last_code_win_before_opencode integer|nil
---@field current_code_buf number|nil
---@field current_code_view table|nil
---@field saved_window_options table|nil
---@field display_route string|nil
---@field current_mode string|nil
---@field last_output number
---@field last_sent_context OpencodeContext|nil
---@field current_context_config OpencodeContextConfig|nil
---@field context_updated_at number|nil
---@field restore_points RestorePoint[]
---@field current_model string|nil
---@field user_mode_model_map table<string, string>
---@field current_model_info table|nil
---@field current_variant string|nil
---@field messages OpencodeMessage[]|nil
---@field current_message OpencodeMessage|nil
---@field pending_permissions OpencodePermission[]
---@field pending_prompt_permissions OpencodePermission[]
---@field pending_questions OpencodeQuestionRequest[]
---@field cost number
---@field tokens_count number
---@field user_message_count table<string, number>
---@field pre_zoom_width integer|nil
---@field last_window_width_ratio number|nil
---@field current_cwd string|nil
---@field session_locked boolean|nil
---@field _hidden_buffers OpencodeHiddenBuffers|nil
---@field context_data OpencodeContext|nil
---@field renderer_context table|nil Renderer caches associated with the preserved output buffer
---@field renderer_dirty boolean Cached renderer missed background session events
---@field background_notifications table<string, boolean> Notifications emitted for pending background prompts

---@class OpencodeSessionTabStateMutations
local M = {}

local RUNTIME_KEYS = {
  'active_session',
  'windows',
  'is_opening',
  'input_content',
  'is_opencode_focused',
  'last_focused_opencode_window',
  'last_input_window_position',
  'last_output_window_position',
  'last_code_win_before_opencode',
  'current_code_buf',
  'current_code_view',
  'saved_window_options',
  'display_route',
  'current_mode',
  'last_output',
  'last_sent_context',
  'current_context_config',
  'context_updated_at',
  'restore_points',
  'current_model',
  'user_mode_model_map',
  'current_model_info',
  'current_variant',
  'messages',
  'current_message',
  'pending_permissions',
  'cost',
  'tokens_count',
  'user_message_count',
  'pre_zoom_width',
  'last_window_width_ratio',
  'current_cwd',
  'session_locked',
  '_hidden_buffers',
}

local UI_KEYS = {
  windows = true,
  input_content = true,
  is_opencode_focused = true,
  last_focused_opencode_window = true,
  last_input_window_position = true,
  last_output_window_position = true,
  last_code_win_before_opencode = true,
  current_code_buf = true,
  current_code_view = true,
  saved_window_options = true,
  display_route = true,
  pre_zoom_width = true,
  last_window_width_ratio = true,
  _hidden_buffers = true,
}

local runtimes = {}
local next_id = 1
local setup_done = false

local function notify_change()
  store.update('session_tabs_changed', function(current)
    return (current or 0) + 1
  end)
end

local function new_id()
  local id = 'tab-' .. next_id
  next_id = next_id + 1
  return id
end

local function default_runtime(id)
  return {
    id = id,
    active_session = nil,
    windows = nil,
    is_opening = false,
    input_content = {},
    is_opencode_focused = false,
    last_focused_opencode_window = nil,
    last_input_window_position = nil,
    last_output_window_position = nil,
    last_code_win_before_opencode = nil,
    current_code_buf = nil,
    current_code_view = nil,
    saved_window_options = nil,
    display_route = nil,
    current_mode = nil,
    last_output = 0,
    last_sent_context = nil,
    current_context_config = nil,
    context_updated_at = nil,
    restore_points = {},
    current_model = nil,
    user_mode_model_map = {},
    current_model_info = nil,
    current_variant = nil,
    messages = nil,
    current_message = nil,
    pending_permissions = {},
    pending_prompt_permissions = {},
    pending_questions = {},
    cost = 0,
    tokens_count = 0,
    user_message_count = {},
    pre_zoom_width = nil,
    last_window_width_ratio = nil,
    current_cwd = vim.fn.getcwd(),
    session_locked = nil,
    _hidden_buffers = nil,
    context_data = nil,
    renderer_context = nil,
    renderer_dirty = false,
    background_notifications = {},
  }
end

local function copy_from_store(runtime)
  for _, key in ipairs(RUNTIME_KEYS) do
    runtime[key] = store.get(key)
  end
end

local function copy_to_store(runtime)
  for _, key in ipairs(RUNTIME_KEYS) do
    store.set(key, runtime[key])
  end
end

local function clear_ui(runtime)
  local defaults = default_runtime(runtime.id)
  for key, _ in pairs(UI_KEYS) do
    runtime[key] = defaults[key]
  end
end

local function runtime_from_current(id, preserve_ui)
  local runtime = default_runtime(id)
  copy_from_store(runtime)
  if not preserve_ui then
    clear_ui(runtime)
  end
  runtime.id = id
  return runtime
end

local function capture_runtime(id)
  local runtime = runtimes[id]
  if not runtime then
    return nil
  end

  copy_from_store(runtime)
  runtime.id = id
  return runtime
end

---@return OpencodeSessionTabRuntime[]
function M.list()
  M.sync()
  local tabs = {}
  for _, runtime in pairs(runtimes) do
    table.insert(tabs, runtime)
  end
  table.sort(tabs, function(a, b)
    local a_order = tonumber(a.id:match('(%d+)$')) or 0
    local b_order = tonumber(b.id:match('(%d+)$')) or 0
    return a_order < b_order
  end)
  return tabs
end

---@param id string
---@return OpencodeSessionTabRuntime|nil
function M.get(id)
  return runtimes[id]
end

---@param session_id string|nil
---@return OpencodeSessionTabRuntime|nil
function M.find_by_session_id(session_id)
  if not session_id or session_id == '' then
    return nil
  end

  M.sync()
  for _, runtime in pairs(runtimes) do
    if runtime.active_session and runtime.active_session.id == session_id then
      return runtime
    end

    local render_state = runtime.renderer_context and runtime.renderer_context.render_state
    if render_state and render_state.get_task_part_by_child_session then
      local ok, task_part = pcall(render_state.get_task_part_by_child_session, render_state, session_id)
      if ok and task_part then
        return runtime
      end
    end
  end

  local current = M.current()
  if current and current.active_session and current.active_session.id then
    local render_state = require('opencode.ui.renderer.ctx').render_state
    if render_state:get_task_part_by_child_session(session_id) then
      return current
    end
  end
end

---@param session_id string|nil
function M.mark_renderer_dirty(session_id)
  if not session_id then
    return
  end

  local runtime_count = 0
  for _ in pairs(runtimes) do
    runtime_count = runtime_count + 1
    if runtime_count > 1 then
      break
    end
  end
  if runtime_count < 2 then
    return
  end

  local runtime = M.find_by_session_id(session_id)
  if runtime and runtime.id ~= M.active_id() then
    runtime.renderer_dirty = true
  end
end

---@param tab_id string
---@param permission OpencodePermission
function M.add_pending_permission(tab_id, permission)
  local runtime = runtimes[tab_id]
  if not runtime or not permission or not permission.id then
    return
  end

  for index, existing in ipairs(runtime.pending_prompt_permissions) do
    if existing.id == permission.id then
      runtime.pending_prompt_permissions[index] = permission
      notify_change()
      return
    end
  end

  table.insert(runtime.pending_prompt_permissions, permission)
  notify_change()
end

---@param tab_id string
---@param permission_id string
function M.remove_pending_permission(tab_id, permission_id)
  local runtime = runtimes[tab_id]
  if not runtime or not permission_id then
    return
  end

  for index, permission in ipairs(runtime.pending_prompt_permissions) do
    if permission.id == permission_id then
      table.remove(runtime.pending_prompt_permissions, index)
      notify_change()
      return
    end
  end
end

---@param tab_id string
---@param question OpencodeQuestionRequest
function M.add_pending_question(tab_id, question)
  local runtime = runtimes[tab_id]
  if not runtime or not question or not question.id then
    return
  end

  for index, existing in ipairs(runtime.pending_questions) do
    if existing.id == question.id then
      runtime.pending_questions[index] = question
      notify_change()
      return
    end
  end

  table.insert(runtime.pending_questions, question)
  notify_change()
end

---@param tab_id string
---@param question_id string
function M.remove_pending_question(tab_id, question_id)
  local runtime = runtimes[tab_id]
  if not runtime or not question_id then
    return
  end

  for index, question in ipairs(runtime.pending_questions) do
    if question.id == question_id then
      table.remove(runtime.pending_questions, index)
      notify_change()
      return
    end
  end
end

---@param tab_id string
function M.clear_pending_prompts(tab_id)
  local runtime = runtimes[tab_id]
  if not runtime then
    return
  end

  local active = M.active_id() == tab_id
  local has_pending = #runtime.pending_permissions > 0
    or #runtime.pending_prompt_permissions > 0
    or #runtime.pending_questions > 0
  if active then
    has_pending = has_pending or #(store.get('pending_permissions') or {}) > 0
  end
  if not has_pending then
    return
  end

  runtime.pending_permissions = {}
  runtime.pending_prompt_permissions = {}
  runtime.pending_questions = {}
  if active then
    store.batch(function()
      store.set('pending_permissions', {})
    end)
  end
  notify_change()
end

---@return OpencodeSessionTabRuntime|nil
function M.current()
  local runtime = runtimes[store.get('active_session_tab')]
  if runtime then
    capture_runtime(runtime.id)
  end
  return runtime
end

---@return string|nil
function M.active_id()
  return store.get('active_session_tab')
end

---@return boolean
function M.is_current_bound()
  return M.current() ~= nil
end

---@param id? string
function M.sync(id)
  id = id or store.get('active_session_tab')
  if id and runtimes[id] then
    capture_runtime(id)
  end
end

---@param context_data OpencodeContext|nil
function M.set_context(context_data)
  local runtime = M.current()
  if runtime then
    runtime.context_data = vim.deepcopy(context_data)
  end
end

---@return OpencodeContext|nil
function M.get_context()
  local runtime = M.current()
  return runtime and vim.deepcopy(runtime.context_data) or nil
end

---@param tab_id string
---@param session_id string
---@param delta integer
function M.update_user_message_count(tab_id, session_id, delta)
  local runtime = runtimes[tab_id]
  if not runtime then
    return
  end

  local counts = vim.deepcopy(runtime.user_message_count or {})
  local next_count = (counts[session_id] or 0) + delta
  counts[session_id] = math.max(0, next_count)
  runtime.user_message_count = counts

  if store.get('active_session_tab') == tab_id then
    store.set('user_message_count', runtime.user_message_count)
  end
end

---@param tab_id string
---@param context_data OpencodeContext|nil
function M.set_last_sent_context(tab_id, context_data)
  local runtime = runtimes[tab_id]
  if not runtime then
    return
  end

  runtime.last_sent_context = vim.deepcopy(context_data)
  if store.get('active_session_tab') == tab_id then
    store.set('last_sent_context', runtime.last_sent_context)
  end
end

---@class OpencodeSessionTabModelUpdate
---@field model? string
---@field mode? string
---@field variant? string

---@param tab_id string
---@param update OpencodeSessionTabModelUpdate
function M.update_model_state(tab_id, update)
  local runtime = runtimes[tab_id]
  if not runtime then
    return
  end

  if update.model ~= nil then
    if runtime.current_model ~= update.model then
      runtime.current_variant = require('opencode.state.model').saved_variant(update.model)
    end
    runtime.current_model = update.model
  end
  if update.mode ~= nil then
    runtime.current_mode = update.mode
  end
  if update.variant ~= nil then
    runtime.current_variant = update.variant
  end

  if store.get('active_session_tab') == tab_id then
    store.batch(function()
      if update.model ~= nil then
        store.set('current_model', update.model)
        store.set('current_variant', runtime.current_variant)
      end
      if update.mode ~= nil then
        store.set('current_mode', update.mode)
      end
      if update.variant ~= nil then
        store.set('current_variant', update.variant)
      end
    end)
  end
end

---@return OpencodeSessionTabRuntime
function M.ensure_current()
  local id = store.get('active_session_tab')
  if id and runtimes[id] then
    capture_runtime(id)
    return runtimes[id]
  end

  id = new_id()
  local runtime = runtime_from_current(id, false)
  runtimes[id] = runtime
  store.set('active_session_tab', id)
  return runtime
end

---@param runtime OpencodeSessionTabRuntime
function M.activate(runtime)
  if type(runtime) == 'string' then
    runtime = runtimes[runtime]
  end
  if not runtime then
    return false
  end

  local previous_id = store.get('active_session_tab')
  if previous_id and previous_id ~= runtime.id then
    capture_runtime(previous_id)
  end

  if previous_id ~= runtime.id then
    store.batch(function()
      copy_to_store(runtime)
      store.set('active_session_tab', runtime.id)
    end)
  else
    capture_runtime(runtime.id)
  end

  return true
end

---@param session Session|nil
---@return OpencodeSessionTabRuntime
function M.create(session)
  local runtime = runtime_from_current(new_id(), false)
  runtime.active_session = session
  runtime.messages = nil
  runtime.current_message = nil
  runtime.pending_permissions = {}
  runtime.pending_prompt_permissions = {}
  runtime.pending_questions = {}
  runtime.restore_points = {}
  runtime.last_sent_context = nil
  runtime.user_message_count = {}
  runtime.cost = 0
  runtime.tokens_count = 0
  runtimes[runtime.id] = runtime
  notify_change()
  return runtime
end

---@param runtime OpencodeSessionTabRuntime
function M.remove(runtime)
  if not runtime then
    return
  end
  runtimes[runtime.id] = nil
  notify_change()
  if store.get('active_session_tab') == runtime.id then
    store.set('active_session_tab', nil)
  end
end

---Reset the in-memory tab registry. Intended for teardown and tests.
function M.reset()
  runtimes = {}
  next_id = 1
  setup_done = false
  store.set_raw('active_session_tab', nil)
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  local runtime = runtime_from_current(new_id(), true)
  runtimes[runtime.id] = runtime
  store.set('active_session_tab', runtime.id)
end

return M
