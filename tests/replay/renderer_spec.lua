local assert = require('luassert')
local config = require('opencode.config')
local helpers = require('tests.helpers')
local output_window = require('opencode.ui.output_window')
local renderer = require('opencode.ui.renderer')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

local function contract()
  return helpers.load_test_data('tests/data/v1/observation-1.18.json')
end

local function lines()
  return vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
end

local function contains_line(pattern)
  for _, line in ipairs(lines()) do
    if line:find(pattern, 1, true) then
      return true
    end
  end
  return false
end

local function contains_virtual_text(pattern)
  local actual = helpers.capture_output(state.windows.output_buf, output_window.namespace)
  for _, mark in ipairs(actual.extmarks) do
    for _, chunk in ipairs(mark[4] and mark[4].virt_text or {}) do
      if type(chunk[1]) == 'string' and chunk[1]:find(pattern, 1, true) then
        return true
      end
    end
  end
  return false
end

describe('renderer V1 Observation contract', function()
  local original_show_ids

  before_each(function()
    original_show_ids = config.debug.show_ids
    config.debug.show_ids = false
    helpers.replay_setup()
  end)

  after_each(function()
    config.debug.show_ids = original_show_ids
    if state.windows then
      ui.close_windows(state.windows)
    end
  end)

  it('renders the fixed V1 snapshot through the public Entry and Content facts', function()
    local data = contract()
    local session = { id = data.sessionID, location = { directory = '/server/project' } }
    state.session.set_active(session)

    renderer._render_full_session_data(helpers.map_v1_messages(data.snapshot, session), session)

    assert.is_true(contains_line('hello'))
    assert.is_true(contains_line('thinking'))
    assert.is_true(contains_virtual_text('BUILD'))
    assert.is_true(contains_line('main.lua'))
    assert.is_true(#helpers.capture_output(state.windows.output_buf, output_window.namespace).extmarks > 0)
  end)

  it('keeps the V1 mode label when the protocol supplies mode and agent', function()
    local data = contract()
    local session = { id = data.sessionID, location = { directory = '/server/project' } }
    state.session.set_active(session)
    local entries = helpers.map_v1_messages(data.snapshot, session)

    renderer._render_full_session_data(entries, session)

    assert.is_true(contains_virtual_text('BUILD'))
    assert.is_false(contains_virtual_text('ASSISTANT'))
  end)

  it('renders an assistant message assembled from the V1 global event stream', function()
    local data = contract()
    state.session.set_active({ id = data.sessionID, location = { directory = '/server/project' } })

    helpers.replay_event(data.events.message)
    helpers.replay_event(data.events.part)
    helpers.replay_event(data.events.delta)

    assert.is_true(contains_line('AB'))
    assert.is_true(contains_virtual_text('BUILD'))
  end)
end)
