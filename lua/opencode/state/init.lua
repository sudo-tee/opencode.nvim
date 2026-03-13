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
---@field set_last_sent_context fun(context: OpencodeContext|nil)
---@field set_user_message_count fun(count: table<string, number>)

---@class OpencodeJobStateMutations
---@field increment_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field decrement_count fun(delta?: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_count fun(count: integer, opts?: OpencodeProtectedStateSetOptions)
---@field set_server fun(server: OpencodeServer|nil, opts?: OpencodeProtectedStateSetOptions)
---@field clear_server fun(opts?: OpencodeProtectedStateSetOptions)
---@field set_api_client fun(client: OpencodeApiClient|nil)
---@field set_event_manager fun(manager: EventManager|nil)
---@field set_opencode_cli_version fun(version: string|nil)

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
---@field set_input_content fun(lines: table)
---@field set_saved_window_options fun(opts: table|nil)
---@field set_pre_zoom_width fun(width: integer|nil)

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

---@class OpencodeRendererStateMutations
---@field set_messages fun(messages: OpencodeMessage[]|nil)
---@field set_current_message fun(message: OpencodeMessage|nil)
---@field set_last_user_message fun(message: OpencodeMessage|nil)
---@field set_pending_permissions fun(permissions: OpencodePermission[])
---@field set_cost fun(cost: number)
---@field set_tokens_count fun(count: number)

---@class OpencodeContextStateMutations
---@field set_current_context_config fun(config: OpencodeContextConfig|nil)
---@field set_context_updated_at fun(timestamp: number|nil)
---@field set_current_cwd fun(cwd: string|nil)

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
---@field renderer OpencodeRendererStateMutations
---@field context OpencodeContextStateMutations

local store = require('opencode.state.store')
local session = require('opencode.state.session')
local jobs = require('opencode.state.jobs')
local ui = require('opencode.state.ui')
local model = require('opencode.state.model')
local renderer = require('opencode.state.renderer')
local context = require('opencode.state.context')

local M = {
  store = store,
  session = session,
  jobs = jobs,
  ui = ui,
  model = model,
  renderer = renderer,
  context = context,
  subscribe = store.subscribe,
  unsubscribe = store.unsubscribe,
  notify = store.notify,
  append = store.append,
  remove = store.remove,
}

function M.is_running()
  return M.job_count > 0
end

return setmetatable(M, {
  __index = function(_, key)
    return store.get(key)
  end,
  __newindex = function(_, key, _value)
    error(string.format('Direct write to state key `%s` is not allowed; use a state domain setter', key), 2)
  end,
  __pairs = function()
    return pairs(store.state())
  end,
  __ipairs = function()
    return ipairs(store.state())
  end,
}) --[[@as OpencodeState]]
