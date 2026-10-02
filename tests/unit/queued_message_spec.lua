local assert = require('luassert')
local config = require('opencode.config')
local helpers = require('tests.helpers')
local replay = require('tests.manual.renderer_replay')
local state = require('opencode.state')
local ui = require('opencode.ui.ui')

describe('V1 queued message projection and display', function()
  local original_show_ids

  local function queued()
    return assert(state.session.active_observation()):read().entries_by_id.msg_queued.queued
  end

  local function has_badge()
    local marks = vim.api.nvim_buf_get_extmarks(
      state.windows.output_buf,
      require('opencode.ui.output_window').namespace,
      0,
      -1,
      { details = true }
    )
    for _, mark in ipairs(marks) do
      for _, chunk in ipairs(mark[4].virt_text or {}) do
        if chunk[1] == ' QUEUED' and chunk[2] == 'OpencodeQueued' then
          return true
        end
      end
    end
    return false
  end

  before_each(function()
    original_show_ids = config.debug.show_ids
    config.debug.show_ids = true
    helpers.replay_setup()
    assert.is_true(replay.load_events('tests/data/queue.json'))
  end)

  after_each(function()
    config.debug.show_ids = original_show_ids
    ui.close_windows(state.windows)
  end)

  it('projects and displays a queued user arriving while the session is busy', function()
    replay.replay_all(0)

    assert.is_true(queued())
    assert.is_true(has_badge())
  end)

  it('keeps the queue fact through metadata updates and idle transitions', function()
    replay.replay_all(0)
    helpers.replay_event({
      type = 'session.status',
      properties = { sessionID = 'ses_queue', status = { type = 'idle' } },
    })
    helpers.replay_event(replay.events[6])

    assert.is_true(queued())
    assert.is_true(has_badge())
  end)

  it('clears the queue fact and rerenders its header when an assistant consumes that user', function()
    replay.replay_all(0)
    helpers.replay_event({
      type = 'message.updated',
      properties = {
        info = {
          id = 'msg_reply',
          sessionID = 'ses_queue',
          role = 'assistant',
          parentID = 'msg_queued',
          time = { created = 1788528293000 },
        },
      },
    })

    assert.is_nil(queued())
    assert.is_false(has_badge())
    assert.equals(
      'This message is queued',
      assert(state.session.active_observation()):read().entries_by_id.msg_queued.content[1].text
    )
  end)

  it('does not mark new user messages queued in an idle session', function()
    helpers.replay_events({ replay.events[1], replay.events[2], replay.events[6], replay.events[7] })

    assert.is_false(queued())
    assert.is_false(has_badge())
  end)

  it('does not clear queued input when an assistant replies to a different user', function()
    replay.replay_all(0)
    helpers.replay_event(replay.events[3])

    assert.is_true(queued())
    assert.is_true(has_badge())
  end)

  it('marks user input arriving during a retry as queued', function()
    helpers.replay_events({
      replay.events[1],
      {
        type = 'session.status',
        properties = {
          sessionID = 'ses_queue',
          status = { type = 'retry', attempt = 1, message = 'Retry', next = 1788528294000 },
        },
      },
      replay.events[6],
      replay.events[7],
    })

    assert.is_true(queued())
    assert.is_true(has_badge())
  end)

  it('preserves known queue state when a message snapshot is refreshed', function()
    replay.replay_all(0)
    local observation = assert(state.session.active_observation())
    require('opencode.protocols.v1.observation').ingest_snapshot(observation, {
      { info = replay.events[6].properties.info, parts = { replay.events[7].properties.part } },
    })

    assert.is_true(queued())
  end)

  it('clears a known queue fact when a refreshed snapshot contains its assistant reply', function()
    replay.replay_all(0)
    local reply = vim.deepcopy(replay.events[3].properties.info)
    reply.id, reply.parentID = 'msg_reply', 'msg_queued'
    require('opencode.protocols.v1.observation').ingest_snapshot(assert(state.session.active_observation()), {
      { info = replay.events[6].properties.info, parts = { replay.events[7].properties.part } },
      { info = reply, parts = {} },
    })

    assert.is_nil(queued())
  end)
end)
