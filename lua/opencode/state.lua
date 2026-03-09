---@class OpencodeWindowState
---@field input_win integer|nil
---@field output_win integer|nil
---@field footer_win integer|nil
---@field footer_buf integer|nil
---@field input_buf integer|nil
---@field output_buf integer|nil
---@field output_was_at_bottom boolean|nil

---@class OpencodeHiddenBuffers
---@field input_buf integer
---@field output_buf integer
---@field footer_buf integer|nil
---@field output_was_at_bottom boolean
---@field input_hidden boolean
---@field input_cursor integer[]|nil
---@field output_cursor integer[]|nil
---@field output_view table|nil
---@field focused_window 'input'|'output'|nil
---@field position 'right'|'left'|'current'|nil
---@field owner_tab integer|nil

---@class OpencodeToggleDecision
---@field action 'open'|'close'|'hide'|'close_hidden'|'restore_hidden'|'migrate'

---@class OpencodeSessionStateMutations
---@field set_active fun(session: Session|nil)
---@field clear_active fun()
---@field set_restore_points fun(points: RestorePoint[])
---@field reset_restore_points fun()

---@class OpencodeProtectedStateSetOptions
---@field source? 'helper'|'raw'

---@alias OpencodeProtectedStateKey
---| 'active_session'
---| 'restore_points'
---| 'job_count'
---| 'opencode_server'
---| 'windows'
---| 'is_opening'
---| 'is_opencode_focused'
---| 'last_focused_opencode_window'
---| 'last_code_win_before_opencode'
---| 'current_code_buf'
---| 'display_route'
---| 'current_mode'
---| 'current_model'
---| 'current_model_info'
---| 'current_variant'
---| 'user_mode_model_map'

---@class OpencodeJobStateMutations
---@field increment_count fun(delta?: integer)
---@field set_count fun(count: integer)
---@field set_server fun(server: OpencodeServer|nil)
---@field clear_server fun()

---@class OpencodeUiStateMutations
---@field set_windows fun(windows: OpencodeWindowState|nil)
---@field clear_windows fun()
---@field set_opening fun(is_opening: boolean)
---@field set_panel_focused fun(is_focused: boolean)
---@field set_last_focused_window fun(win_type: 'input'|'output'|nil)
---@field set_display_route fun(route: any)
---@field clear_display_route fun()
---@field set_last_code_window fun(win_id: integer|nil)
---@field set_current_code_buf fun(bufnr: integer|nil)

---@class OpencodeModelStateMutations
---@field set_mode fun(mode: string|nil)
---@field clear_mode fun()
---@field set_model fun(model: string|nil)
---@field clear_model fun()
---@field set_model_info fun(info: table|nil)
---@field set_variant fun(variant: string|nil)
---@field clear_variant fun()
---@field set_mode_model_map fun(mode_map: table<string, string>)
---@field set_mode_model_override fun(mode: string, model: string)

---@class OpencodeState
---@field windows OpencodeWindowState|nil
---@field is_opening boolean
---@field input_content table
---@field is_opencode_focused boolean
---@field last_focused_opencode_window string|nil
---@field last_input_window_position integer[]|nil
---@field last_output_window_position integer[]|nil
---@field last_code_win_before_opencode integer|nil
---@field current_code_buf number|nil
---@field saved_window_options table|nil
---@field display_route any|nil
---@field current_mode string
---@field last_output number
---@field last_sent_context OpencodeContext|nil
---@field current_context_config OpencodeContextConfig|nil
---@field context_updated_at number|nil
---@field active_session Session|nil
---@field restore_points RestorePoint[]
---@field current_model string|nil
---@field user_mode_model_map table<string, string>
---@field current_model_info table|nil
---@field current_variant string|nil
---@field messages OpencodeMessage[]|nil
---@field current_message OpencodeMessage|nil
---@field last_user_message OpencodeMessage|nil
---@field pending_permissions OpencodePermission[]
---@field cost number
---@field tokens_count number
---@field job_count number
---@field user_message_count table<string, number>
---@field opencode_server OpencodeServer|nil
---@field api_client OpencodeApiClient
---@field event_manager EventManager|nil
---@field pre_zoom_width integer|nil
---@field last_window_width_ratio number|nil
---@field required_version string
---@field opencode_cli_version string|nil
---@field current_cwd string|nil
---@field _hidden_buffers OpencodeHiddenBuffers|nil
---@field append fun( key:string, value:any)
---@field remove fun( key:string, idx:number)
---@field subscribe fun( key:string|string[]|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field unsubscribe fun( key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field is_running fun():boolean
---@field get_window_state fun(): {status: 'closed'|'hidden'|'visible', position: string, windows: OpencodeWindowState|nil, cursor_positions: {input: integer[]|nil, output: integer[]|nil}}
---@field is_window_in_current_tab fun(win_id: integer|nil): boolean
---@field are_windows_in_current_tab fun(): boolean
---@field get_window_cursor fun(win_id: integer|nil): integer[]|nil
---@field set_cursor_position fun(win_type: 'input'|'output', pos: integer[]|nil)
---@field get_cursor_position fun(win_type: 'input'|'output'): integer[]|nil
---@field stash_hidden_buffers fun(hidden: OpencodeHiddenBuffers|nil)
---@field inspect_hidden_buffers fun(): OpencodeHiddenBuffers|nil
---@field is_hidden_snapshot_in_current_tab fun(): boolean
---@field clear_hidden_window_state fun()
---@field has_hidden_buffers fun(): boolean
---@field consume_hidden_buffers fun(): OpencodeHiddenBuffers|nil
---@field resolve_toggle_decision fun(persist_state: boolean, has_display_route: boolean): OpencodeToggleDecision
---@field resolve_open_windows_action fun(): 'reuse_visible'|'restore_hidden'|'create_fresh'
---@field get_window_cursor fun(win_id: integer|nil): integer[]|nil
---@field session OpencodeSessionStateMutations
---@field jobs OpencodeJobStateMutations
---@field ui OpencodeUiStateMutations
---@field model OpencodeModelStateMutations

local M = {}

-- Internal raw state table
local _state = {
  -- ui
  windows = nil, ---@type OpencodeWindowState|nil
  is_opening = false,
  input_content = {},
  is_opencode_focused = false,
  last_focused_opencode_window = nil,
  last_input_window_position = nil,
  last_output_window_position = nil,
  last_code_win_before_opencode = nil,
  current_code_buf = nil,
  saved_window_options = nil,
  display_route = nil,
  current_mode = nil,
  last_output = 0,
  pre_zoom_width = nil,
  -- context
  last_sent_context = nil,
  current_context_config = {},
  context_updated_at = nil,
  -- session
  active_session = nil,
  restore_points = {},
  current_model = nil,
  user_mode_model_map = {},
  current_model_info = nil,
  current_variant = nil,
  -- messages
  messages = nil,
  current_message = nil,
  last_user_message = nil,
  pending_permissions = {},
  cost = 0,
  tokens_count = 0,
  -- job
  job_count = 0,
  user_message_count = {},
  opencode_server = nil,
  api_client = nil,
  event_manager = nil,

  -- versions
  required_version = '0.6.3',
  opencode_cli_version = nil,
  current_cwd = vim.fn.getcwd(),

  -- persist_state snapshot
  _hidden_buffers = nil,
}

-- Listener registry: { [key] = {cb1, cb2, ...}, ['*'] = {cb1, ...} }
local _listeners = {}

local PROTECTED_KEYS = {
  active_session = true,
  restore_points = true,
  job_count = true,
  opencode_server = true,
  windows = true,
  is_opening = true,
  is_opencode_focused = true,
  last_focused_opencode_window = true,
  last_code_win_before_opencode = true,
  current_code_buf = true,
  display_route = true,
  current_mode = true,
  current_model = true,
  current_model_info = true,
  current_variant = true,
  user_mode_model_map = true,
}

local _protected_write_warnings = {}

---@param key string
---@param value any
---@param opts? OpencodeProtectedStateSetOptions
local function set_state(key, value, opts)
  local old = _state[key]
  opts = opts or { source = 'helper' }

  if opts.source == 'raw' then
    warn_on_protected_raw_write(key)
  end

  _state[key] = value
  if not vim.deep_equal(old, value) then
    M.notify(key, value, old)
  end
end

---@generic T
---@param key string
---@param updater fun(current: T): T
---@return T
local function update_state(key, updater)
  local next_value = updater(_state[key])
  set_state(key, next_value)
  return next_value
end

M.session = {}

---@param session Session|nil
function M.session.set_active(session)
  set_state('active_session', session)
end

function M.session.clear_active()
  set_state('active_session', nil)
end

---@param points RestorePoint[]
function M.session.set_restore_points(points)
  set_state('restore_points', points)
end

function M.session.reset_restore_points()
  set_state('restore_points', {})
end

M.jobs = {}

---@param delta integer|nil
function M.jobs.increment_count(delta)
  update_state('job_count', function(current)
    return (current or 0) + (delta or 1)
  end)
end

---@param count integer
function M.jobs.set_count(count)
  set_state('job_count', count)
end

---@param server OpencodeServer|nil
function M.jobs.set_server(server)
  set_state('opencode_server', server)
end

function M.jobs.clear_server()
  set_state('opencode_server', nil)
end

M.ui = {}

---@param windows OpencodeWindowState|nil
function M.ui.set_windows(windows)
  set_state('windows', windows)
end

function M.ui.clear_windows()
  set_state('windows', nil)
end

---@param is_opening boolean
function M.ui.set_opening(is_opening)
  set_state('is_opening', is_opening)
end

---@param is_focused boolean
function M.ui.set_panel_focused(is_focused)
  set_state('is_opencode_focused', is_focused)
end

---@param win_type 'input'|'output'|nil
function M.ui.set_last_focused_window(win_type)
  set_state('last_focused_opencode_window', win_type)
end

---@param route any
function M.ui.set_display_route(route)
  set_state('display_route', route)
end

function M.ui.clear_display_route()
  set_state('display_route', nil)
end

---@param win_id integer|nil
function M.ui.set_last_code_window(win_id)
  set_state('last_code_win_before_opencode', win_id)
end

---@param bufnr integer|nil
function M.ui.set_current_code_buf(bufnr)
  set_state('current_code_buf', bufnr)
end

M.model = {}

---@param mode string|nil
function M.model.set_mode(mode)
  set_state('current_mode', mode)
end

function M.model.clear_mode()
  set_state('current_mode', nil)
end

---@param model string|nil
function M.model.set_model(model)
  set_state('current_model', model)
end

function M.model.clear_model()
  set_state('current_model', nil)
end

---@param info table|nil
function M.model.set_model_info(info)
  set_state('current_model_info', info)
end

---@param variant string|nil
function M.model.set_variant(variant)
  set_state('current_variant', variant)
end

function M.model.clear_variant()
  set_state('current_variant', nil)
end

---@param mode_map table<string, string>
function M.model.set_mode_model_map(mode_map)
  set_state('user_mode_model_map', mode_map)
end

---@param mode string
---@param model string
function M.model.set_mode_model_override(mode, model)
  local mode_map = vim.deepcopy(_state.user_mode_model_map)
  mode_map[mode] = model
  set_state('user_mode_model_map', mode_map)
end

---@param key string
local function warn_on_protected_raw_write(key)
  if not PROTECTED_KEYS[key] or _protected_write_warnings[key] then
    return
  end

  _protected_write_warnings[key] = true
  vim.schedule(function()
    vim.notify(
      string.format('Direct write to protected state key `%s`; prefer state domain helpers', key),
      vim.log.levels.WARN
    )
  end)
end

--- Subscribe to changes for a key (or all keys with '*').
---@param key string|string[]|nil If nil or '*', listens to all keys
---@param cb fun(key:string, new_val:any, old_val:any)
---@usage
---   state.subscribe('foo', function(key, new, old) ... end)
---   state.subscribe('*', function(key, new, old) ... end)
function M.subscribe(key, cb)
  if type(key) == 'table' then
    for _, k in ipairs(key) do
      M.subscribe(k, cb)
    end
    return
  end
  key = key or '*'
  if not _listeners[key] then
    _listeners[key] = {}
  end

  for _, fn in ipairs(_listeners[key]) do
    if fn == cb then
      return
    end
  end

  table.insert(_listeners[key], cb)
end

--- Unsubscribe a callback for a key (or all keys)
---@param key string|nil
---@param cb fun(key:string, new_val:any, old_val:any)
function M.unsubscribe(key, cb)
  key = key or '*'
  local list = _listeners[key]
  if not list then
    return
  end

  for i = #list, 1, -1 do
    local fn = list[i]
    if fn == cb then
      table.remove(list, i)
    end
  end
end

-- Notify listeners
function M.notify(key, new_val, old_val)
  -- schedule notification to make sure we're not in a fast event
  -- context
  vim.schedule(function()
    if _listeners[key] then
      for _, cb in ipairs(_listeners[key]) do
        local ok, err = pcall(cb, key, new_val, old_val)
        if not ok then
          vim.notify(err --[[@as string]])
        end
      end
    end
    if _listeners['*'] then
      for _, cb in ipairs(_listeners['*']) do
        pcall(cb, key, new_val, old_val)
      end
    end
  end)
end

function M.append(key, value)
  if type(value) ~= 'table' then
    error('Value must be a table to append')
  end
  if not _state[key] then
    _state[key] = {}
  end
  if type(_state[key]) ~= 'table' then
    error('State key is not a table: ' .. key)
  end

  local old = vim.deepcopy(_state[key] --[[@as table]])
  table.insert(_state[key] --[[@as table]], value)
  M.notify(key, _state[key], old)
end

function M.remove(key, idx)
  if not _state[key] then
    return
  end
  if type(_state[key]) ~= 'table' then
    error('State key is not a table: ' .. key)
  end

  local old = vim.deepcopy(_state[key] --[[@as table]])
  table.remove(_state[key] --[[@as table]], idx)
  M.notify(key, _state[key], old)
end

---
--- Returns true if any job (run or server) is running
---
function M.is_running()
  return M.job_count > 0
end

---@param win_id integer|nil
---@return boolean
function M.is_window_in_current_tab(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then
    return false
  end

  local current_tab = vim.api.nvim_get_current_tabpage()
  local ok, win_tab = pcall(vim.api.nvim_win_get_tabpage, win_id)
  return ok and win_tab == current_tab
end

---@return boolean
function M.are_windows_in_current_tab()
  if not _state.windows then
    return false
  end

  return M.is_window_in_current_tab(_state.windows.input_win) or M.is_window_in_current_tab(_state.windows.output_win)
end

---@return boolean
function M.is_visible()
  return M.get_window_state().status == 'visible'
end

---@class OpencodeToggleContext
---@field status 'closed'|'hidden'|'visible'
---@field in_tab boolean
---@field persist_state boolean
---@field has_display_route boolean

---@generic T
---@param rules T[]
---@param match fun(rule: T): boolean
---@return T|nil
local function first_matching_rule(rules, match)
  for _, rule in ipairs(rules) do
    if match(rule) then
      return rule
    end
  end

  return nil
end

--- ORDER MATTERS: Rules are evaluated top-to-bottom; first match wins.
--- In particular, the has_display_route rule must precede the persist_state=true/hide rule,
--- otherwise toggling while viewing /help or /commands would hide instead of close.
local TOGGLE_ACTION_RULES = {
  {
    action = 'restore_hidden',
    when = function(ctx)
      return ctx.status == 'hidden' and ctx.persist_state
    end,
  },
  {
    action = 'close_hidden',
    when = function(ctx)
      return ctx.status == 'hidden' and not ctx.persist_state
    end,
  },
  {
    action = 'migrate',
    when = function(ctx)
      return ctx.status == 'visible' and not ctx.in_tab
    end,
  },
  {
    action = 'close',
    when = function(ctx)
      return ctx.status == 'visible' and ctx.in_tab and ctx.has_display_route
    end,
  },
  {
    action = 'close',
    when = function(ctx)
      return ctx.status == 'visible' and ctx.in_tab and not ctx.persist_state
    end,
  },
  {
    action = 'hide',
    when = function(ctx)
      return ctx.status == 'visible' and ctx.in_tab and ctx.persist_state and not ctx.has_display_route
    end,
  },
  {
    action = 'open',
    when = function(ctx)
      return ctx.status == 'closed'
    end,
  },
}

---@param status 'closed'|'hidden'|'visible'
---@param in_tab boolean
---@param persist_state boolean
---@param has_display_route boolean
---@return 'open'|'close'|'hide'|'close_hidden'|'restore_hidden'|'migrate'
local function lookup_toggle_action(status, in_tab, persist_state, has_display_route)
  local ctx = {
    status = status,
    in_tab = in_tab,
    persist_state = persist_state,
    has_display_route = has_display_route,
  }

  local matched_rule = first_matching_rule(TOGGLE_ACTION_RULES, function(rule)
    return rule.when(ctx)
  end)

  return matched_rule and matched_rule.action or 'open'
end

---@param persist_state boolean
---@param has_display_route boolean
---@return OpencodeToggleDecision
function M.resolve_toggle_decision(persist_state, has_display_route)
  local status = M.get_window_state().status
  local in_tab = M.are_windows_in_current_tab()

  local action = lookup_toggle_action(status, in_tab, persist_state, has_display_route)
  return { action = action }
end

---@return 'reuse_visible'|'restore_hidden'|'create_fresh'
function M.resolve_open_windows_action()
  local status = M.get_window_state().status
  if status == 'visible' then
    return M.are_windows_in_current_tab() and 'reuse_visible' or 'create_fresh'
  end
  if status == 'hidden' then
    return 'restore_hidden'
  end
  return 'create_fresh'
end

---@param pos any
---@return integer[]|nil
local function normalize_cursor(pos)
  if type(pos) ~= 'table' or #pos < 2 then
    return nil
  end

  local line = tonumber(pos[1])
  local col = tonumber(pos[2])
  if not line or not col then
    return nil
  end

  return { math.max(1, math.floor(line)), math.max(0, math.floor(col)) }
end

---Get cursor position from a window (pure query, no side effects)
---@param win_id integer|nil
---@return integer[]|nil
function M.get_window_cursor(win_id)
  if not win_id or not vim.api.nvim_win_is_valid(win_id) then
    return nil
  end

  local ok, pos = pcall(vim.api.nvim_win_get_cursor, win_id)
  if not ok then
    return nil
  end

  return normalize_cursor(pos)
end

---Set saved cursor position
---@param win_type 'input'|'output'
---@param pos integer[]|nil
function M.set_cursor_position(win_type, pos)
  local normalized = normalize_cursor(pos)
  if win_type == 'input' then
    _state.last_input_window_position = normalized
  elseif win_type == 'output' then
    _state.last_output_window_position = normalized
  end
end

---Get saved cursor position
---@param win_type 'input'|'output'
---@return integer[]|nil
function M.get_cursor_position(win_type)
  if win_type == 'input' then
    return normalize_cursor(_state.last_input_window_position)
  end
  if win_type == 'output' then
    return normalize_cursor(_state.last_output_window_position)
  end
  return nil
end

---@param hidden OpencodeHiddenBuffers|nil
---@return OpencodeHiddenBuffers|nil
local function normalize_hidden_buffers(hidden)
  if type(hidden) ~= 'table' then
    return nil
  end

  local function valid_buf(b)
    return type(b) == 'number' and vim.api.nvim_buf_is_valid(b)
  end
  if not valid_buf(hidden.input_buf) or not valid_buf(hidden.output_buf) then
    return nil
  end
  if type(hidden.input_hidden) ~= 'boolean' then
    return nil
  end

  local fw = hidden.focused_window
  return {
    input_buf = hidden.input_buf,
    output_buf = hidden.output_buf,
    footer_buf = valid_buf(hidden.footer_buf) and hidden.footer_buf or nil,
    output_was_at_bottom = hidden.output_was_at_bottom == true,
    input_hidden = hidden.input_hidden,
    input_cursor = normalize_cursor(hidden.input_cursor),
    output_cursor = normalize_cursor(hidden.output_cursor),
    output_view = type(hidden.output_view) == 'table' and vim.deepcopy(hidden.output_view) or nil,
    focused_window = (fw == 'input' or fw == 'output') and fw or nil,
    position = hidden.position,
    owner_tab = type(hidden.owner_tab) == 'number' and hidden.owner_tab or nil,
  }
end

---@param copy boolean
---@return OpencodeHiddenBuffers|nil
local function read_hidden_buffers_snapshot(copy)
  local normalized = normalize_hidden_buffers(_state._hidden_buffers)
  if not normalized then
    return nil
  end

  if not copy then
    return normalized
  end

  return vim.deepcopy(normalized)
end

---@return boolean
function M.is_hidden_snapshot_in_current_tab()
  local hidden = read_hidden_buffers_snapshot(false)
  if not hidden then
    return false
  end

  if type(hidden.owner_tab) ~= 'number' then
    return true
  end

  return hidden.owner_tab == vim.api.nvim_get_current_tabpage()
end

---Store hidden buffers snapshot
---@param hidden OpencodeHiddenBuffers|nil
function M.stash_hidden_buffers(hidden)
  if hidden == nil then
    _state._hidden_buffers = nil
    return
  end

  _state._hidden_buffers = normalize_hidden_buffers(hidden)
end

---Inspect hidden buffers snapshot without mutating state
---@return OpencodeHiddenBuffers|nil
function M.inspect_hidden_buffers()
  return read_hidden_buffers_snapshot(true)
end

---Clear hidden snapshot and drop empty window state
function M.clear_hidden_window_state()
  _state._hidden_buffers = nil
  if _state.windows and not _state.windows.input_win and not _state.windows.output_win then
    _state.windows = nil
  end
end

---Check if hidden buffers snapshot is available
---@return boolean
function M.has_hidden_buffers()
  return read_hidden_buffers_snapshot(false) ~= nil
end

---Consume hidden buffers snapshot
---@return OpencodeHiddenBuffers|nil
function M.consume_hidden_buffers()
  local hidden = M.inspect_hidden_buffers()
  _state._hidden_buffers = nil
  return hidden
end

---@return boolean
local function is_visible_in_tab()
  local w = _state.windows
  if not w then
    return false
  end
  local input_valid = w.input_win and vim.api.nvim_win_is_valid(w.input_win)
  local output_valid = w.output_win and vim.api.nvim_win_is_valid(w.output_win)
  return ((input_valid or output_valid) and M.are_windows_in_current_tab()) == true
end

-- STATUS_DETECTION rules for get_window_state (evaluated in order)
local STATUS_DETECTION = {
  {
    name = 'hidden_snapshot',
    test = function()
      return M.has_hidden_buffers() and M.is_hidden_snapshot_in_current_tab()
    end,
    status = 'hidden',
    get_windows = function()
      return nil
    end,
  },
  {
    name = 'visible_in_tab',
    test = is_visible_in_tab,
    status = 'visible',
    get_windows = function()
      return _state.windows
    end,
  },
  {
    name = 'closed',
    test = function()
      return true
    end,
    status = 'closed',
    get_windows = function()
      return nil
    end,
  },
}

---Get comprehensive window state for API consumers
---@return {status: 'closed'|'hidden'|'visible', position: string, windows: OpencodeWindowState|nil, cursor_positions: {input: integer[]|nil, output: integer[]|nil}}
function M.get_window_state()
  local config = require('opencode.config')

  local status_rule = first_matching_rule(STATUS_DETECTION, function(rule)
    return rule.test()
  end)

  local status = status_rule and status_rule.status or 'closed'
  local current_windows = status_rule and status_rule.get_windows() or nil

  return {
    status = status,
    position = config.ui.position,
    windows = current_windows and vim.deepcopy(current_windows) or nil,
    cursor_positions = {
      input = M.get_window_cursor(current_windows and current_windows.input_win) or M.get_cursor_position('input'),
      output = M.get_window_cursor(current_windows and current_windows.output_win) or M.get_cursor_position('output'),
    },
  }
end

--- Observable state proxy. All reads/writes go through this table.
--- Use `state.subscribe(key, cb)` to listen for changes.
--- Use `state.unsubscribe(key, cb)` to remove listeners.
---
--- Example:
---   state.subscribe('foo', function(key, new, old) print(key, new, old) end)
---   state.foo = 42 -- triggers callback
return setmetatable(M, {
  __index = function(_, k)
    return _state[k]
  end,
  __newindex = function(_, k, v)
    set_state(k, v, { source = 'raw' })
  end,
  __pairs = function()
    return pairs(_state)
  end,
  __ipairs = function()
    return ipairs(_state)
  end,
}) --[[@as OpencodeState]]
