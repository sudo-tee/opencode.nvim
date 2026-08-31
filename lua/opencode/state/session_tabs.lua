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

  runtime.user_message_count = runtime.user_message_count or {}
  local next_count = (runtime.user_message_count[session_id] or 0) + delta
  runtime.user_message_count[session_id] = math.max(0, next_count)

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
  runtime.restore_points = {}
  runtime.last_sent_context = nil
  runtime.user_message_count = {}
  runtime.cost = 0
  runtime.tokens_count = 0
  runtimes[runtime.id] = runtime
  return runtime
end

---@param runtime OpencodeSessionTabRuntime
function M.remove(runtime)
  if not runtime then
    return
  end
  runtimes[runtime.id] = nil
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
