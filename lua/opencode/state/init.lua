local store = require('opencode.state.store')
local session = require('opencode.state.session')
local jobs = require('opencode.state.jobs')
local ui = require('opencode.state.ui')
local model = require('opencode.state.model')
local renderer = require('opencode.state.renderer')
local context = require('opencode.state.context')

---@class OpencodeStateModule
---@field store OpencodeStateStore
---@field session OpencodeSessionStateMutations
---@field jobs OpencodeJobStateMutations
---@field ui OpencodeUiStateMutations
---@field model OpencodeModelStateMutations
---@field renderer OpencodeRendererStateMutations
---@field context OpencodeContextStateMutations

---@alias OpencodeState OpencodeStateModule & OpencodeStateData

---@type OpencodeState
local M = {
  store = store,
  session = session,
  jobs = jobs,
  ui = ui,
  model = model,
  renderer = renderer,
  context = context,
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
