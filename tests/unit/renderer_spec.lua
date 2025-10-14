local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')
local helpers = require('tests.helpers')
local output_renderer = require('opencode.ui.output_renderer')
local config_file = require('opencode.config_file')

describe('renderer', function()
  local restore_time_ago

  before_each(function()
    renderer.reset()

    local empty_promise = require('opencode.promise').new():resolve(nil)
    config_file.config_promise = empty_promise
    config_file.project_promise = empty_promise
    config_file.providers_promise = empty_promise

    state.windows = ui.create_windows()

    output_renderer._cleanup_subscriptions()

    restore_time_ago = helpers.mock_time_ago()

    local config = require('opencode.config')
    if not config.config then
      config.config = vim.deepcopy(config.defaults)
    end
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end

    if restore_time_ago then
      restore_time_ago()
    end
  end)

  local json_files = vim.fn.glob('tests/data/*.json', false, true)

  for _, filepath in ipairs(json_files) do
    local name = vim.fn.fnamemodify(filepath, ':t:r')

    if not name:match('%.expected$') then
      local expected_path = 'tests/data/' .. name .. '.expected.json'

      if vim.fn.filereadable(expected_path) == 1 then
        it('replays ' .. name .. ' correctly', function()
          local events = helpers.load_test_data(filepath)
          state.active_session = helpers.get_session_from_events(events)
          local expected = helpers.load_test_data(expected_path)

          helpers.replay_events(events)
          vim.wait(200)

          local actual = helpers.capture_output(state.windows.output_buf, renderer._namespace)

          assert.are.same(expected.lines, actual.lines)
          assert.are.same(expected.extmarks, helpers.normalize_namespace_ids(actual.extmarks))
        end)
      end
    end
  end
end)
