local streaming_renderer = require('opencode.ui.streaming_renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

local function load_test_data(filename)
  local f = io.open(filename, 'r')
  if not f then
    error('Could not open ' .. filename)
  end
  local content = f:read('*all')
  f:close()
  return vim.json.decode(content)
end

local function replay_events(events)
  for _, event in ipairs(events) do
    if event.type == 'message.updated' then
      streaming_renderer.handle_message_updated(event)
    elseif event.type == 'message.part.updated' then
      streaming_renderer.handle_part_updated(event)
    elseif event.type == 'message.removed' then
      streaming_renderer.handle_message_removed(event)
    elseif event.type == 'message.part.removed' then
      streaming_renderer.handle_part_removed(event)
    elseif event.type == 'session.compacted' then
      streaming_renderer.handle_session_compacted()
    end
  end
end

local function capture_output()
  local buf = state.windows.output_buf
  return {
    lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false),
    extmarks = vim.api.nvim_buf_get_extmarks(buf, streaming_renderer._namespace, 0, -1, { details = true }),
  }
end

local function normalize_namespace_ids(extmarks)
  local normalized = vim.deepcopy(extmarks)
  for _, mark in ipairs(normalized) do
    if mark[4] and mark[4].ns_id then
      mark[4].ns_id = 3
    end
  end
  return normalized
end

describe('streaming_renderer', function()
  local original_time_ago

  before_each(function()
    streaming_renderer.reset()
    state.windows = ui.create_windows()

    local util = require('opencode.util')
    original_time_ago = util.time_ago
    util.time_ago = function(timestamp)
      if timestamp > 1e12 then
        timestamp = math.floor(timestamp / 1000)
      end
      return os.date('%Y-%m-%d %H:%M:%S', timestamp)
    end
  end)

  after_each(function()
    if state.windows then
      ui.close_windows(state.windows)
    end

    local util = require('opencode.util')
    util.time_ago = original_time_ago
  end)

  it('replays simple-session correctly', function()
    local events = load_test_data('tests/data/simple-session.json')
    local expected = load_test_data('tests/data/simple-session.expected.json')

    replay_events(events)

    vim.wait(100)

    local actual = capture_output()

    assert.are.same(expected.lines, actual.lines)
    assert.are.same(expected.extmarks, normalize_namespace_ids(actual.extmarks))
  end)

  it('replays updating-text correctly', function()
    local events = load_test_data('tests/data/updating-text.json')
    local expected = load_test_data('tests/data/updating-text.expected.json')

    replay_events(events)

    vim.wait(100)

    local actual = capture_output()

    assert.are.same(expected.lines, actual.lines)
    assert.are.same(expected.extmarks, normalize_namespace_ids(actual.extmarks))
  end)
end)
