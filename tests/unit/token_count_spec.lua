local assert = require('luassert')
local stub = require('luassert.stub')

local state = require('opencode.state')
local events = require('opencode.ui.renderer.events')
local flush = require('opencode.ui.renderer.flush')
local renderer = require('opencode.ui.renderer')
local ctx = require('opencode.ui.renderer.ctx')

local function assistant_message(id, tokens)
  return {
    info = {
      id = id,
      role = 'assistant',
      sessionID = 'ses_1',
      providerID = 'test-provider',
      modelID = 'test-model',
      tokens = tokens,
    },
    parts = {},
  }
end

local REASONING_TOKENS = { input = 1000, output = 200, reasoning = 300, cache = { read = 50, write = 25 } }
local REASONING_TOTAL = 1575

describe('context token count', function()
  local scroll_stub
  local reconcile_stub
  local mark_dirty_stub

  before_each(function()
    scroll_stub = stub(renderer, 'scroll_to_bottom')
    reconcile_stub = stub(renderer, 'reconcile_rendered_message_limit')
    mark_dirty_stub = stub(flush, 'mark_message_dirty')

    ctx:reset()
    state.session.set_active({ id = 'ses_1' })
    state.renderer.set_messages({})
    state.renderer.set_tokens_count(0)
    state.model.clear()
  end)

  after_each(function()
    scroll_stub:revert()
    reconcile_stub:revert()
    mark_dirty_stub:revert()

    ctx:reset()
    state.session.clear_active()
    state.renderer.set_messages({})
    state.renderer.set_tokens_count(0)
    state.model.clear()
  end)

  it('includes reasoning tokens in the context total', function()
    events.on_message_updated(assistant_message('msg_1', REASONING_TOKENS))

    assert.equal(REASONING_TOTAL, state.tokens_count)
  end)

  it('ignores responses without output tokens, matching the TUI', function()
    events.on_message_updated(assistant_message('msg_1', REASONING_TOKENS))
    assert.equal(REASONING_TOTAL, state.tokens_count)

    events.on_message_updated(
      assistant_message('msg_2', { input = 100, output = 0, reasoning = 500, cache = { read = 0, write = 0 } })
    )

    assert.equal(REASONING_TOTAL, state.tokens_count)
  end)

  it('derives the same total from step-finish parts', function()
    local message =
      assistant_message('msg_1', { input = 0, output = 0, reasoning = 0, cache = { read = 0, write = 0 } })
    state.renderer.set_messages({ message })

    events.on_part_updated({
      part = {
        id = 'part_1',
        messageID = 'msg_1',
        sessionID = 'ses_1',
        type = 'step-finish',
        tokens = REASONING_TOKENS,
      },
    })

    assert.equal(REASONING_TOTAL, state.tokens_count)
  end)
end)
