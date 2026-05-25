local helpers = require('tests.helpers')
local config = require('opencode.config')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local output_window = require('opencode.ui.output_window')

local M = {}

local function wait_for_idle(timeout_ms)
  timeout_ms = timeout_ms or 5000

  return vim.wait(timeout_ms, function()
    local emitter = state.event_manager and state.event_manager.throttling_emitter
    if not emitter then
      return true
    end

    return #emitter.queue == 0 and not emitter.drain_scheduled
  end, 10)
end

local function with_ftplugin_disabled(fn)
  local original = vim.g.did_load_ftplugin
  vim.g.did_load_ftplugin = 1

  local ok, result = xpcall(fn, debug.traceback)
  vim.g.did_load_ftplugin = original

  if not ok then
    error(result)
  end

  return result
end

---@param data_file string
---@param expected_file string
function M.run(data_file, expected_file)
  if not data_file or data_file == '' then
    error('Missing data file path')
  end
  if not expected_file or expected_file == '' then
    error('Missing expected file path')
  end

  config.debug.show_ids = true

  local ok, err = xpcall(function()
    with_ftplugin_disabled(function()
      helpers.replay_setup()
    end)

    local events = helpers.load_test_data(data_file)
    state.session.set_active(helpers.get_session_from_events(events))
    helpers.replay_events(events)

    if not wait_for_idle() then
      error('Timed out waiting for replay events to drain')
    end

    local actual = helpers.capture_output(state.windows and state.windows.output_buf, output_window.namespace)
    local snapshot = {
      lines = actual.lines,
      extmarks = helpers.normalize_namespace_ids(actual.extmarks),
      actions = actual.actions,
      timestamp = os.time(),
    }

    local json = vim.json.encode(snapshot, { indent = '  ', sort_keys = true })
    local file = assert(io.open(expected_file, 'w'))
    file:write(json)
    file:close()
  end, debug.traceback)

  if state.windows then
    ui.close_windows(state.windows)
  end

  if not ok then
    error(err)
  end
end

return M
