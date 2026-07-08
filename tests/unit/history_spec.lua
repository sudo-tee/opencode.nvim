local history = require('opencode.history')
local state = require('opencode.state')

local function make_message(id, parts, opts)
  opts = opts or {}
  return {
    info = {
      id = id,
      sessionID = opts.sessionID or 'ses_1',
      role = opts.role or 'user',
      time = { created = opts.created or 0 },
    },
    parts = parts,
  }
end

local function set_messages(messages, session_id)
  local sid = session_id or 'ses_1'
  state.session.set_active({ id = sid })
  for _, m in ipairs(messages) do
    m.info = m.info or {}
    m.info.sessionID = m.info.sessionID or sid
  end
  state.renderer.set_messages(messages)
end

describe('opencode.history', function()
  before_each(function()
    history.reset()
    state.renderer.set_messages(nil)
    state.session.set_active({ id = 'ses_1' })
  end)

  it('returns an empty list when there is no active session', function()
    state.session.set_active(nil)
    state.renderer.set_messages({ make_message('m1', { { type = 'text', text = 'hi' } }) })
    assert.same({}, history.read())
  end)

  it('returns user messages newest-first', function()
    set_messages({
      make_message('m_old', { { type = 'text', text = 'first' } }, { created = 1 }),
      make_message('m_new', { { type = 'text', text = 'second' } }, { created = 2 }),
    })
    local entries = history.read()
    assert.equals(2, #entries)
    assert.equals('m_new', entries[1].id)
    assert.equals('m_old', entries[2].id)
  end)

  it('skips assistant messages and synthetic-only user messages', function()
    set_messages({
      make_message('m_user', { { type = 'text', text = 'real' } }),
      make_message('m_synth', { { type = 'text', synthetic = true, text = 'skip me' } }, { created = 2 }),
      make_message('m_asst', { { type = 'text', text = 'reply' } }, { role = 'assistant', created = 3 }),
    })
    local entries = history.read()
    assert.equals(1, #entries)
    assert.equals('m_user', entries[1].id)
  end)

  it('skips user messages that have no real content', function()
    set_messages({
      make_message('m_blank', { { type = 'text', synthetic = true } }),
      make_message('m_real', { { type = 'text', text = 'keep' } }, { created = 2 }),
    })
    local entries = history.read()
    assert.equals(1, #entries)
    assert.equals('m_real', entries[1].id)
  end)

  it('preserves file and agent mentions in the reconstructed prompt', function()
    set_messages({
      make_message('m1', {
        { type = 'text', text = 'look at' },
        { type = 'file', filename = 'lua/foo.lua' },
        { type = 'agent', name = 'build' },
      }),
    })
    local entries = history.read()
    assert.equals(1, #entries)
    assert.same({ 'look at', '@lua/foo.lua ', '@build ' }, entries[1].prompt.lines)
    assert.same({ 'lua/foo.lua', 'build' }, entries[1].prompt.mention_paths)
  end)

  it('prev walks newest -> oldest and captures the draft on first call', function()
    set_messages({
      make_message('m_old', { { type = 'text', text = 'first' } }, { created = 1 }),
      make_message('m_new', { { type = 'text', text = 'second' } }, { created = 2 }),
    })
    state.ui.set_input_content({ 'my draft' })

    local first = history.prev()
    assert.is_not_nil(first)
    assert.equals('m_new', first.id)

    local second = history.prev()
    assert.equals('m_old', second.id)

    -- Third call caps at the oldest entry.
    local third = history.prev()
    assert.equals('m_old', third.id)
  end)

  it('next returns the captured draft once it walks past the newest entry', function()
    set_messages({
      make_message('m_new', { { type = 'text', text = 'second' } }, { created = 2 }),
    })
    state.ui.set_input_content({ 'my draft' })

    history.prev()
    local back = history.next()
    assert.same({ 'my draft' }, back)
  end)

  it('next returns the entry table while still inside the ring and the draft lines past the newest', function()
    set_messages({
      make_message('m_old', { { type = 'text', text = 'first' } }, { created = 1 }),
      make_message('m_new', { { type = 'text', text = 'second' } }, { created = 2 }),
    })
    state.ui.set_input_content({ 'draft' })

    -- Walk back to the oldest first so a single forward step lands on an
    -- entry (index 2 -> index 1) and a second forward step crosses past
    -- the newest (index 1 -> draft).
    history.prev() -- index 1, returned m_new
    history.prev() -- index 2, returned m_old

    local entry_step = history.next()
    assert.is_table(entry_step)
    assert.is_not_nil(entry_step.message)
    assert.equals('m_new', entry_step.id)

    local draft_step = history.next()
    assert.is_table(draft_step)
    assert.is_nil(draft_step.message)
    assert.same({ 'draft' }, draft_step)
  end)

  it('reset clears the ring cursor and captured draft', function()
    set_messages({
      make_message('m1', { { type = 'text', text = 'hi' } }),
    })
    state.ui.set_input_content({ 'draft' })
    history.prev()
    history.reset()
    -- After reset the next forward navigation has nothing to restore and the
    -- backward navigation restarts from the newest entry, not from where we
    -- left off.
    assert.is_nil(history.next())
    local entry = history.prev()
    assert.is_not_nil(entry)
    assert.equals('m1', entry.id)
  end)

  it('reset triggers when the active session changes', function()
    set_messages({
      make_message('m1', { { type = 'text', text = 'a' } }, { sessionID = 'ses_1' }),
    }, 'ses_1')
    state.ui.set_input_content({ 'draft' })
    history.prev()

    -- Switch session: index should reset, so prev() returns the newest entry
    -- of the new session (not continue from the old index).
    set_messages({
      make_message('m2', { { type = 'text', text = 'b' } }, { sessionID = 'ses_2' }),
    }, 'ses_2')

    local entry = history.prev()
    assert.is_not_nil(entry)
    assert.equals('m2', entry.id)
  end)
end)
