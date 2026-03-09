local store = require('opencode.state.store')

local M = {}

local function disable_warnings()
  store.set_protected_writes_silenced(true)
end

local function enable_warnings()
  store.set_protected_writes_silenced(false)
end

function M.allow_raw_writes_for_tests()
  disable_warnings()
  return enable_warnings
end

function M.silence_protected_writes()
  return M.allow_raw_writes_for_tests()
end

function M.restore_protected_write_warnings()
  enable_warnings()
end

return M
