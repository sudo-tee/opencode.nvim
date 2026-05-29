local helpers = require('tests.helpers')
local state = require('opencode.state')
local ctx = require('opencode.ui.renderer.ctx')
local stub = require('luassert.stub')

---Create a minimal message for testing lazy render.
---@param id string Message ID
---@param role string 'user' or 'assistant'
---@return OpencodeMessage
local function make_message(id, role)
  return {
    info = {
      id = id,
      sessionID = 'ses_test',
      role = role,
      time = { created = 1000 },
    },
    parts = {
      {
        id = id .. '_part',
        messageID = id,
        sessionID = 'ses_test',
        type = 'text',
        text = 'Message ' .. id,
        state = {},
      },
    },
  }
end

---Create a list of N user/assistant message pairs.
---@param count integer Number of message pairs
---@return OpencodeMessage[]
local function make_session_data(count)
  local messages = {}
  for i = 1, count do
    table.insert(messages, make_message('msg_u' .. i, 'user'))
    table.insert(messages, make_message('msg_a' .. i, 'assistant'))
  end
  return messages
end

---Count rendered real messages (excluding synthetic notices) in the render_state.
---@return integer
local function count_rendered_messages()
  local count = 0
  for _, msg in ipairs(state.messages or {}) do
    local msg_id = msg.info and msg.info.id or ''
    -- Skip synthetic messages (hidden notice, revert display)
    if msg_id:match('^__opencode_') then
      goto continue
    end
    local rendered = ctx.render_state:get_message(msg_id)
    if rendered and rendered.line_start and rendered.line_end then
      count = count + 1
    end
    ::continue::
  end
  return count
end

describe('lazy render', function()
  local renderer

  before_each(function()
    helpers.replay_setup()
    renderer = require('opencode.ui.renderer')

    state.session.set_active({ id = 'ses_test', title = 'Test Session' })
  end)

  after_each(function()
    ctx:reset()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('renders all messages when lazy=false', function()
    local session_data = make_session_data(10)
    renderer._render_full_session_data(session_data, { lazy = false })

    -- All 20 messages (10 user + 10 assistant) should be rendered
    assert.are.equal(20, count_rendered_messages())
  end)

  it('renders limited messages when ctx.lazy_render_count is set', function()
    local session_data = make_session_data(50) -- 100 messages total

    -- Set lazy_render_count before calling render — this simulates
    -- load_more_messages having been called previously
    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data, { lazy = true })

    -- Only 10 of 100 messages should be rendered (from the end)
    assert.are.equal(10, count_rendered_messages())
    -- lazy_render_count should be preserved (written back by render)
    assert.are.equal(10, ctx.lazy_render_count)
  end)

  it('preserves lazy_render_count increment across render reset', function()
    -- This is the core test for the bug: load_more_messages sets
    -- ctx.lazy_render_count, but _render_full_session_data calls M.reset()
    -- which used to clear it. After the fix, lazy_render_count is read
    -- before reset() and written back after.

    local session_data = make_session_data(50) -- 100 messages total

    -- Simulate initial load: render with lazy=true
    -- Stub get_initial_render_count to return a small number so lazy kicks in
    local initial_count = 10
    -- We can't easily stub a local function, so set ctx.lazy_render_count
    -- directly to simulate what would happen after initial render
    ctx.lazy_render_count = initial_count
    renderer._render_full_session_data(session_data, { lazy = true })
    assert.are.equal(initial_count, count_rendered_messages())
    assert.are.equal(initial_count, ctx.lazy_render_count)

    -- Now simulate load_more_messages: increment lazy_render_count
    local incremented = initial_count + 10
    ctx.lazy_render_count = incremented

    -- This render should preserve the incremented value across reset
    renderer._render_full_session_data(session_data, { lazy = true })
    assert.are.equal(incremented, count_rendered_messages())
    assert.are.equal(
      incremented,
      ctx.lazy_render_count,
      'lazy_render_count should survive M.reset() — the original bug would clear it'
    )
  end)

  it('load_more_messages increments rendered message count', function()
    local session_data = make_session_data(50) -- 100 messages total

    -- Simulate initial lazy render with 10 messages
    ctx.lazy_render_count = 10
    renderer._render_full_session_data(session_data, { lazy = true })
    assert.are.equal(10, count_rendered_messages())

    -- Call load_more_messages
    local result = renderer.load_more_messages()
    assert.is_true(result, 'load_more_messages should return true when more messages available')
    -- lazy_render_count should have been incremented
    assert.is_true(
      ctx.lazy_render_count > 10,
      'lazy_render_count should be incremented, got ' .. tostring(ctx.lazy_render_count)
    )
  end)

  it('load_more_messages returns false when all messages are loaded', function()
    local session_data = make_session_data(5) -- 10 messages total

    -- Render with lazy_render_count covering all messages
    ctx.lazy_render_count = 100
    renderer._render_full_session_data(session_data, { lazy = true })

    -- All messages are loaded, load_more should return false
    local result = renderer.load_more_messages()
    assert.is_false(result, 'load_more_messages should return false when all loaded')
  end)

  it('load_more_messages returns false when no messages', function()
    -- Render with empty data
    renderer._render_full_session_data({}, { lazy = true })

    local result = renderer.load_more_messages()
    assert.is_false(result, 'load_more_messages should return false when no messages')
  end)
end)

describe('renderer no debug logging', function()
  before_each(function()
    helpers.replay_setup()
    state.session.set_active({ id = 'ses_test', title = 'Test Session' })
  end)

  after_each(function()
    ctx:reset()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('does not emit INFO-level notifications during rendering', function()
    local mock = helpers.mock_notify()
    local renderer = require('opencode.ui.renderer')
    local session_data = make_session_data(5)

    renderer._render_full_session_data(session_data, { lazy = false })

    -- Process any vim.schedule callbacks
    vim.wait(100)

    local notifications = mock.get_notifications()
    mock.reset()

    for _, n in ipairs(notifications) do
      if n.level == vim.log.levels.INFO then
        assert.is_not_match(
          '%[render_full%]',
          n.msg,
          'DEBUG: [render_full] notification should not be emitted: ' .. n.msg
        )
        assert.is_not_match('%[e2e%]', n.msg, 'DEBUG: [e2e] notification should not be emitted: ' .. n.msg)
      end
    end
  end)
end)
