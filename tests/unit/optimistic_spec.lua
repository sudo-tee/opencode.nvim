local optimistic = require('opencode.state.optimistic')
local support = require('tests.unit.services_spec_support')
local assert = require('luassert')

describe('optimistic prompt state', function()
  local observation

  before_each(function()
    observation = support.mock_connection():observe({ id = 'optimistic-session' })
  end)

  it('projects a prompt immediately without mutating server history', function()
    local prompt = optimistic.begin(observation, 'hello')
    local entries = optimistic.project(observation, {})
    assert.equals(prompt.id, entries[1].id)
    assert.equals('hello', entries[1].content[1].text)
    assert.equals('sending', entries[1].local_status)
    assert.is_true(optimistic.is_sending(observation))
    assert.same({}, observation:read().entries_by_id)
    assert.same({}, observation:read().entry_order)
  end)

  it('reconciles by ID even when the echo arrives before acknowledgement', function()
    local prompt = optimistic.begin(observation, 'hello')
    local echo = { id = 'server-id', kind = 'user', content = {} }
    observation:read().entries_by_id[echo.id] = echo
    optimistic.bind(prompt, echo.id)
    assert.same({ echo }, optimistic.project(observation, { echo }))
    assert.is_false(optimistic.is_sending(observation))
  end)

  it('does not resurface a prompt after its server echo leaves observed history', function()
    local prompt = optimistic.begin(observation, 'hello')
    local echo = { id = 'server-id', kind = 'user', content = {} }
    optimistic.bind(prompt, echo.id)
    observation:read().entries_by_id[echo.id] = echo
    assert.same({ echo }, optimistic.project(observation, { echo }))

    observation:read().entries_by_id[echo.id] = nil
    assert.same({}, optimistic.project(observation, {}))
    assert.is_false(optimistic.is_sending(observation))
    optimistic.finish(observation, prompt)
  end)

  it('does not match another client or repeated prompt by text', function()
    local first = optimistic.begin(observation, 'same')
    local second = optimistic.begin(observation, 'same')
    optimistic.bind(first, 'first')
    optimistic.bind(second, 'second')
    observation:read().entries_by_id.first = { id = 'first' }
    local projected = optimistic.project(observation, {})
    assert.equals(1, #projected)
    assert.equals(second.id, projected[1].id)
  end)

  it('keeps failed and uncertain text copyable without spinning forever', function()
    local prompt = optimistic.begin(observation, 'retry me')
    optimistic.finish(observation, prompt, 'failed')
    assert.equals('failed', optimistic.project(observation, {})[1].local_status)
    assert.is_false(optimistic.is_sending(observation))
    optimistic.finish(observation, prompt, 'unknown')
    assert.equals('unknown', optimistic.project(observation, {})[1].local_status)
    optimistic.finish(observation, prompt)
    assert.same({}, optimistic.project(observation, {}))
  end)

  it('isolates sessions and connections', function()
    optimistic.begin(observation, 'private')
    local other = support.mock_connection():observe({ id = 'optimistic-session' })
    assert.same({}, optimistic.project(other, {}))
    assert.is_false(optimistic.is_sending(other))
  end)
end)
