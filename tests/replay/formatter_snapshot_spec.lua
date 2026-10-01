local assert = require('luassert')
local config = require('opencode.config')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local replay = require('tests.manual.renderer_replay')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

describe('V2 formatter JSON replay snapshots', function()
  local original_show_ids

  before_each(function()
    original_show_ids = config.debug.show_ids
    config.debug.show_ids = true
    helpers.replay_setup()
  end)

  after_each(function()
    config.debug.show_ids = original_show_ids
    ui.close_windows(state.windows)
  end)

  for _, name in ipairs({
    'formatters',
    'system-skill',
    'shell',
    'compaction',
    'location-switched',
    'execute-results',
    'mcp-results',
    'generic-results',
  }) do
    it('replays tests/data/v2/' .. name .. '.json into its expected snapshot', function()
      local input_file = 'tests/data/v2/' .. name .. '.json'
      local expected_file = replay.get_expected_filename(input_file)
      local expected = helpers.load_test_data(expected_file)
      if vim.fn.has('nvim-0.11') == 0 then
        -- Neovim 0.10 escapes forward slashes in JSON; newer versions do not.
        for index, line in ipairs(expected.lines) do
          if line:match('^{.*}$') then
            expected.lines[index] = vim.json.encode(vim.json.decode(line))
          end
        end
      end
      assert.is_true(replay.load_events(input_file))
      assert.is_true(replay.replay_full_session())
      local initial = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      initial.window, expected.window = nil, nil
      assert.same(expected, initial)

      replay.reset()
      replay.replay_next(#replay.events)
      assert.is_true(replay.wait_for_idle())

      local actual = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      -- Viewport dimensions vary between interactive Neovim and headless tests.
      actual.window, expected.window = nil, nil
      assert.same(expected, actual)

      assert.is_true(replay.replay_full_session())
      local full = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      full.window = nil
      assert.same(expected, full)

      replay.replay_all(0)
      local reset = helpers.output_snapshot(state.windows.output_buf, output_window.namespace, expected_file)
      reset.window = nil
      assert.same(expected, reset)
    end)
  end
end)
