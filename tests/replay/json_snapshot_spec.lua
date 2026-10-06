local assert = require('luassert')
local config = require('opencode.config')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local replay = require('tests.manual.renderer_replay')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local snapshot_assertions = require('tests.snapshot_assertions')

describe('JSON replay snapshots', function()
  local original_show_ids
  local original_notify

  before_each(function()
    original_show_ids = config.debug.show_ids
    original_notify = vim.notify
    vim.notify = function(message, level, opts)
      if level == vim.log.levels.WARN or level == vim.log.levels.ERROR then
        original_notify(message, level, opts)
      end
    end
    config.debug.show_ids = true
    helpers.replay_setup()
  end)

  after_each(function()
    helpers.restore_replay_environment()
    config.debug.show_ids = original_show_ids
    vim.notify = original_notify
    ui.close_windows(state.windows)
  end)

  local snapshots = vim.fn.glob('tests/data/**/*.expected.json', false, true)
  table.sort(snapshots)
  for _, expected_file in ipairs(snapshots) do
    local input_file = expected_file:gsub('%.expected%.json$', '.json')
    it('replays ' .. input_file .. ' into its expected snapshot', function()
      io.stdout:write('Replaying: ' .. input_file .. '\n')
      io.stdout:flush()
      local expected = helpers.load_test_data(expected_file)
      assert.is_true(replay.load_events(input_file))
      if replay.events[1].type ~= 'replay.v2.message' and replay.events[1].protocol ~= 'v2' then
        replay.replay_all(0)
        assert.is_true(replay.wait_for_idle())
        local actual = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
        -- Legacy fixtures also carry viewport overrides for full-session rendering.
        expected.session_window = nil
        actual.window, expected.window = nil, nil
        snapshot_assertions.assert_same(expected, actual)
        return
      end
      assert.is_true(replay.replay_full_session())
      local initial = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      initial.window, expected.window = nil, nil
      snapshot_assertions.assert_same(expected, initial)

      replay.reset()
      replay.replay_next(#replay.events)
      assert.is_true(replay.wait_for_idle())

      local actual = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      -- Viewport dimensions vary between interactive Neovim and headless tests.
      actual.window, expected.window = nil, nil
      snapshot_assertions.assert_same(expected, actual)

      assert.is_true(replay.replay_full_session())
      local full = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      full.window = nil
      snapshot_assertions.assert_same(expected, full)

      replay.replay_all(0)
      local reset = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      reset.window = nil
      snapshot_assertions.assert_same(expected, reset)
    end)
  end
end)
