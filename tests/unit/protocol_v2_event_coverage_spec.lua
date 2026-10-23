local contract = require('opencode.protocols.v2.event_contract')
local events = require('opencode.protocols.v2.observation.events')

local handled = events.handled_types()

---Explicit sources are required checks; PATH discovery is optional because
---opencode may be V1 or a launcher rather than the compiled V2 distribution.
---@param explicit? string
---@param executable string
---@return string[]? events
---@return string? skip_reason
local function upstream_events(explicit, executable)
  if explicit then
    assert(
      vim.fn.filereadable(explicit) == 1 or vim.fn.isdirectory(explicit) == 1,
      'OPENCODE_EVENTS_SOURCE does not exist or is unreadable: ' .. explicit
    )
    return contract.extract_session_events(explicit)
  end
  if executable == '' then
    return nil, 'no opencode installation found'
  end
  local real = vim.fn.resolve(executable)
  if vim.fn.filereadable(real) ~= 1 then
    return nil, 'opencode executable is unreadable: ' .. real
  end
  local extracted = contract.extract_session_events(real)
  for _, event_type in ipairs(extracted) do
    if event_type == 'session.execution.started' or event_type == 'session.inbox.enqueued' then
      return extracted
    end
  end
  return nil, 'installed opencode has no embedded V2 event schema (it may be a launcher or V1): ' .. real
end

describe('V2 event contract coverage', function()
  it('adjudicates every upstream session event', function()
    local extracted, reason = upstream_events(vim.env.OPENCODE_EVENTS_SOURCE, vim.fn.exepath('opencode'))
    if not extracted then
      local message = reason .. '; set OPENCODE_EVENTS_SOURCE to the V2 binary/schema directory to require this check'
      print('[event-contract] SKIPPED: ' .. message)
      pending(message)
      return
    end
    assert.is_true(
      #extracted > 30,
      'extraction found only ' .. #extracted .. ' session events; the source is probably not the schema file'
    )
    local unknown_in_source, unadjudicated, stale_adjudications = contract.check(handled, extracted)
    assert.same({}, unknown_in_source, 'handler keys that are not upstream events')
    assert.same({}, unadjudicated, 'upstream events with no handler, exemption, or known-gap entry')
    assert.same({}, stale_adjudications, 'exempt/gap entries whose event no longer exists upstream')
  end)

  it('documents a reason for every exempt event and a consequence for every known gap', function()
    for event_type, reason in pairs(contract.EXEMPT) do
      assert.is_string(reason, 'exempt entry ' .. event_type .. ' has no reason')
      assert.truthy(#reason > 20, 'exempt reason for ' .. event_type .. ' is too thin')
    end
    for event_type, consequence in pairs(contract.KNOWN_GAPS) do
      assert.is_string(consequence, 'known gap ' .. event_type .. ' has no consequence note')
      assert.is_nil(handled[event_type], 'known gap ' .. event_type .. ' is now handled; move it out of KNOWN_GAPS')
    end
  end)
end)

describe('V2 event contract source discovery', function()
  local source

  before_each(function()
    source = vim.fn.tempname()
  end)

  after_each(function()
    vim.fn.delete(source)
  end)

  it('skips absent installations', function()
    local extracted, reason = upstream_events(nil, '')
    assert.is_nil(extracted)
    assert.matches('no opencode installation', reason)
  end)

  it('skips launcher scripts without trying to execute them', function()
    vim.fn.writefile({ '#!/bin/sh', 'exec /nix/store/example/bin/.opencode-wrapped "$@"' }, source)
    local extracted, reason = upstream_events(nil, source)
    assert.is_nil(extracted)
    assert.matches('no embedded V2 event schema', reason)
  end)

  it('skips V1 event schemas', function()
    vim.fn.writefile({ 'type: "session.updated"', 'type: "session.status"' }, source)
    local extracted, reason = upstream_events(nil, source)
    assert.is_nil(extracted)
    assert.matches('no embedded V2 event schema', reason)
  end)

  it('keeps discovered V2 events for strict coverage assertions', function()
    vim.fn.writefile({ 'type: "session.execution.started"', 'type: "session.new.event"' }, source)
    local extracted = upstream_events(nil, source)
    assert.same({ 'session.execution.started', 'session.new.event' }, extracted)
  end)

  it('rejects missing explicit sources instead of falling back or skipping', function()
    assert.has_error(function()
      upstream_events(source, '')
    end, 'OPENCODE_EVENTS_SOURCE does not exist or is unreadable: ' .. source)
  end)

  it('keeps empty explicit sources for strict extraction assertions', function()
    vim.fn.writefile({ '#!/bin/sh' }, source)
    assert.same({}, upstream_events(source, ''))
  end)
end)
