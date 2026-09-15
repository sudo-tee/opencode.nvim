local store = require('opencode.state.store')
local session = require('opencode.state.session')
local jobs = require('opencode.state.jobs')
local ui = require('opencode.state.ui')
local model = require('opencode.state.model')
local renderer = require('opencode.state.renderer')
local context = require('opencode.state.context')
local session_tabs = require('opencode.state.session_tabs')

---@class OpencodeState : OpencodeStateData
---@field store OpencodeStateStore
---@field session OpencodeSessionStateMutations
---@field jobs OpencodeJobStateMutations
---@field ui OpencodeUiStateMutations
---@field model OpencodeModelStateMutations
---@field renderer OpencodeRendererStateMutations
---@field context OpencodeContextStateMutations
---@field session_tabs OpencodeSessionTabStateMutations
---@field active_session Session|nil
---@field active_session_tab string|nil
---@field session_tabs_changed number
---@field current_model string|nil
---@field api_client OpencodeApiClient|nil

---@type OpencodeState
local M = {
  store = store,
  session = session,
  jobs = jobs,
  ui = ui,
  model = model,
  renderer = renderer,
  context = context,
  session_tabs = session_tabs,
}

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
