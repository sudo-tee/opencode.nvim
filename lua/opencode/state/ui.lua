local store = require('opencode.state.store')

---@class OpencodeToggleDecision
---@field action 'open'|'close'|'hide'|'close_hidden'|'restore_hidden'|'migrate'

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

---@class OpencodeWindowState
---@field input_win integer|nil
---@field output_win integer|nil
---@field footer_win integer|nil
---@field footer_buf integer|nil
---@field input_buf integer|nil
---@field output_buf integer|nil
---@field output_was_at_bottom boolean|nil

---@class OpencodeUiStateMutations
local M = {}

local _state = store.state()

---@param windows OpencodeWindowState|nil
function M.set_windows(windows)
  return store.set('windows', windows)
end

function M.clear_windows()
  return store.set('windows', nil)
end

---@param is_opening boolean
function M.set_opening(is_opening)
  return store.set('is_opening', is_opening)
end

---@param is_focused boolean
function M.set_panel_focused(is_focused)
  return store.set('is_opencode_focused', is_focused)
end

---@param win_type 'input'|'output'|nil
function M.set_last_focused_window(win_type)
  return store.set('last_focused_opencode_window', win_type)
end

---@param route any
function M.set_display_route(route)
  return store.set('display_route', route)
end

function M.clear_display_route()
  return store.set('display_route', nil)
end

---@param win_id integer|nil
function M.set_last_code_window(win_id)
  return store.set('last_code_win_before_opencode', win_id)
end

---@param bufnr integer|nil
function M.set_current_code_buf(bufnr)
  return store.set('current_code_buf', bufnr)
end

---@param win_id integer|nil
---@param bufnr integer|nil
function M.set_code_context(win_id, bufnr)
  store.batch(function()
    store.set('last_code_win_before_opencode', win_id)
    store.set('current_code_buf', bufnr)
  end)
end

---Clear window IDs while keeping buffer references, used when hiding windows
---@param output_was_at_bottom boolean
function M.mark_windows_hidden(output_was_at_bottom)
  store.mutate('windows', function(win)
    win.input_win = nil
    win.output_win = nil
    win.footer_win = nil
    win.output_was_at_bottom = output_was_at_bottom
  end)
end

---@param ratio number|nil
function M.set_last_window_width_ratio(ratio)
  return store.set('last_window_width_ratio', ratio)
end

function M.clear_last_window_width_ratio()
  return store.set('last_window_width_ratio', nil)
end

---@param lines table<string>|nil
function M.set_input_content(lines)
  return store.set('input_content', lines)
end

---@param opts table|nil
function M.set_saved_window_options(opts)
  return store.set('saved_window_options', opts)
end

---@param width integer|nil
function M.set_pre_zoom_width(width)
  return store.set('pre_zoom_width', width)
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

---@param win_type 'input'|'output'
---@param pos integer[]|nil
function M.set_cursor_position(win_type, pos)
  local normalized = normalize_cursor(pos)
  if win_type == 'input' then
    store.set('last_input_window_position', normalized)
  elseif win_type == 'output' then
    store.set('last_output_window_position', normalized)
  end
end

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

  local function valid_buf(buf)
    return type(buf) == 'number' and vim.api.nvim_buf_is_valid(buf)
  end

  if not valid_buf(hidden.input_buf) or not valid_buf(hidden.output_buf) then
    return nil
  end
  if type(hidden.input_hidden) ~= 'boolean' then
    return nil
  end

  local focused_window = hidden.focused_window
  return {
    input_buf = hidden.input_buf,
    output_buf = hidden.output_buf,
    footer_buf = valid_buf(hidden.footer_buf) and hidden.footer_buf or nil,
    output_was_at_bottom = hidden.output_was_at_bottom == true,
    input_hidden = hidden.input_hidden,
    input_cursor = normalize_cursor(hidden.input_cursor),
    output_cursor = normalize_cursor(hidden.output_cursor),
    output_view = type(hidden.output_view) == 'table' and vim.deepcopy(hidden.output_view) or nil,
    focused_window = (focused_window == 'input' or focused_window == 'output') and focused_window or nil,
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

---@param hidden OpencodeHiddenBuffers|nil
function M.stash_hidden_buffers(hidden)
  if hidden == nil then
    store.set('_hidden_buffers', nil)
    return
  end

  store.set('_hidden_buffers', normalize_hidden_buffers(hidden))
end

---@return OpencodeHiddenBuffers|nil
function M.inspect_hidden_buffers()
  return read_hidden_buffers_snapshot(true)
end

function M.clear_hidden_window_state()
  return store.batch(function()
    store.set('_hidden_buffers', nil)
    if _state.windows and not _state.windows.input_win and not _state.windows.output_win then
      store.set('windows', nil)
    end
  end)
end

---@return boolean
function M.has_hidden_buffers()
  return read_hidden_buffers_snapshot(false) ~= nil
end

---@return OpencodeHiddenBuffers|nil
function M.consume_hidden_buffers()
  local hidden = M.inspect_hidden_buffers()
  store.set('_hidden_buffers', nil)
  return hidden
end

---@return boolean
local function is_visible_in_tab()
  local windows = _state.windows
  if not windows then
    return false
  end
  local input_valid = windows.input_win and vim.api.nvim_win_is_valid(windows.input_win)
  local output_valid = windows.output_win and vim.api.nvim_win_is_valid(windows.output_win)
  return ((input_valid or output_valid) and M.are_windows_in_current_tab()) == true
end

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

---@return boolean
function M.is_visible()
  return M.get_window_state().status == 'visible'
end

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

return M
