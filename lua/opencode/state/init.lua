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
---@field set_active fun(session: Session|nil, opts?: OpencodeProtectedStateSetOptions)
---@field clear_active fun(opts?: OpencodeProtectedStateSetOptions)
---@field set_restore_points fun(points: RestorePoint[], opts?: OpencodeProtectedStateSetOptions)
---@field reset_restore_points fun(opts?: OpencodeProtectedStateSetOptions)

---@class OpencodeJobStateMutations
---@field increment_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field decrement_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_count fun(count: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_server fun(server: OpencodeServer|nil, opts?: OpencodeProtectedStateSetOptions)
---@field clear_server fun(opts?: OpencodeProtectedStateSetOptions)

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
---@field set_last_window_width_ratio fun(ratio: number|nil)
---@field clear_last_window_width_ratio fun()

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
---@field append fun(key:string, value:any)
---@field remove fun(key:string, idx:number)
---@field subscribe fun(key:string|string[]|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field unsubscribe fun(key:string|nil, cb:fun(key:string, new_val:any, old_val:any))
---@field is_running fun():boolean
---@field session OpencodeSessionStateMutations
---@field jobs OpencodeJobStateMutations
---@field ui OpencodeUiStateMutations
---@field model OpencodeModelStateMutations

local store = require('opencode.state.store')
local session = require('opencode.state.session')
local jobs = require('opencode.state.jobs')
local ui = require('opencode.state.ui')
local model = require('opencode.state.model')
local test_helpers = require('opencode.state.test_helpers')

local M = {
  store = store,
  session = session,
  jobs = jobs,
  ui = ui,
  model = model,
  test_helpers = test_helpers,
  subscribe = store.subscribe,
  unsubscribe = store.unsubscribe,
  notify = store.notify,
  append = store.append,
  remove = store.remove,
  set_raw = store.set_raw,
  allow_raw_writes_for_tests = test_helpers.allow_raw_writes_for_tests,
  silence_protected_writes = test_helpers.silence_protected_writes,
}

function M.is_running()
  return M.job_count > 0
end

return setmetatable(M, {
  __index = function(_, key)
    return store.get(key)
  end,
  __newindex = function(_, key, value)
    store.set(key, value, { source = 'raw' })
  end,
  __pairs = function()
    return pairs(store.state())
  end,
  __ipairs = function()
    return ipairs(store.state())
  end,
}) --[[@as OpencodeState]]
