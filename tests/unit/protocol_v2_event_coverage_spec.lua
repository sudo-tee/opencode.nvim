local contract = require('opencode.protocols.v2.event_contract')
local events = require('opencode.protocols.v2.observation.events')
local messages = require('opencode.protocols.v2.observation.messages')

---Every handler key registered across the observation modules.
---M.routes is the merged dispatch table (inbox/execution/permissions/questions/session)
---and M.handlers covers the message-resource events.
local handled = {}
for event_type in pairs(events.routes) do
  handled[event_type] = true
end
for event_type in pairs(messages.handlers) do
  handled[event_type] = true
end

---Locate the opencode distribution to extract the event union from.
---Priority: explicit OPENCODE_EVENTS_SOURCE (file or schema directory), then a
---real opencode executable on the machine — the compiled bundle carries the
---full durable+ephemeral event surface, so any local install covers the check.
local function schema_source()
  local explicit = vim.env.OPENCODE_EVENTS_SOURCE
  if explicit and (vim.fn.filereadable(explicit) == 1 or vim.fn.isdirectory(explicit) == 1) then
    return explicit
  end
  local exe = vim.fn.exepath('opencode')
  if exe == '' then
    return nil
  end
  local real = vim.fn.resolve(exe)
  return vim.fn.filereadable(real) == 1 and real or nil
end

describe('V2 event contract coverage', function()
  local source = schema_source()

  it('adjudicates every upstream session event', function()
    if not source then
      print('[event-contract] SKIPPED: no opencode installation found')
      pending(
        'no opencode installation found; install opencode or set OPENCODE_EVENTS_SOURCE to its binary/schema directory to run this check'
      )
      return
    end
    local upstream_events = contract.extract_session_events(source)
    assert.is_true(
      #upstream_events > 30,
      'extraction found only ' .. #upstream_events .. ' session events; the source is probably not the schema file'
    )
    local unknown_in_source, unadjudicated, stale_adjudications = contract.check(handled, upstream_events)
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
