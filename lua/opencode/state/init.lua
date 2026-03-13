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
  emit = store.emit,
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
