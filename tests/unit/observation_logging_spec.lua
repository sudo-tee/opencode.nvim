-- Contract violations and unknown session events must leave traces in the log file.
-- log.lua captures its path and level at require time, and tests/minimal/init.lua
-- already loaded it (pointed at the real stdpath), so this spec points config.logging
-- at a temp file, purges the affected modules, and re-requires them before exercising
-- the observation entry points.
local assert = require('luassert')
local config = require('opencode.config')

local original_logging = {
  enabled = config.logging.enabled,
  level = config.logging.level,
  outfile = config.logging.outfile,
}

local logging_logfile = vim.fn.tempname() .. '-observation-logging.log'

local function point_logging_at_spec_file()
  config.logging.enabled = true
  config.logging.level = 'debug'
  config.logging.outfile = logging_logfile
end

local function restore_logging()
  config.logging.enabled = original_logging.enabled
  config.logging.level = original_logging.level
  config.logging.outfile = original_logging.outfile
end

point_logging_at_spec_file()

for _, name in ipairs({
  'opencode.log',
  'opencode.protocols.observation',
  'opencode.protocols.v1.observation',
  'opencode.protocols.v2.observation',
  'opencode.protocols.v2.observation.messages',
  'opencode.protocols.v2.observation.boundary',
  'opencode.protocols.v2.observation.events',
  'opencode.protocols.v2.event_contract',
}) do
  package.loaded[name] = nil
end

local log = require('opencode.log')
local v1_observation = require('opencode.protocols.v1.observation')
local v2_observation = require('opencode.protocols.v2.observation')
local v2_events = require('opencode.protocols.v2.observation.events')

local function read_log()
  local path = log.get_path()
  local file = path and io.open(path, 'r')
  if not file then
    return ''
  end
  local content = file:read('*a')
  file:close()
  return content or ''
end

local function count_occurrences(content, pattern)
  local count = 0
  for _ in content:gmatch(pattern) do
    count = count + 1
  end
  return count
end

local function v1_observation_for(session_id)
  local connection = require('opencode.opencode_server').from_custom('http://v1.test')
  connection.protocol = 'v1'
  connection.server_identity = { version = '1.18.30' }
  connection.credential = { username = 'opencode' }
  connection:mark_ready()
  return connection:observe({
    id = session_id,
    location = { directory = '/server/project' },
  })
end

local function v1_contract()
  local path = vim.fn.getcwd() .. '/tests/data/v1/observation-1.18.json'
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local function v2_observation_for(session_id)
  local connection = require('opencode.opencode_server').from_custom('http://v2.test')
  connection.protocol = 'v2'
  connection.server_identity = { version = '2.0.1' }
  connection.credential = { username = 'opencode' }
  connection:mark_ready()
  return connection:observe({ id = session_id })
end

local function v2_event(session_id, kind, data, created)
  data.sessionID = session_id
  return { id = 'evt-fixed', type = kind, created = created or 300, data = data }
end

describe('observation logging', function()
  before_each(point_logging_at_spec_file)
  after_each(restore_logging)

  it('logs a warn entry when a V1 contract violation is recorded', function()
    local contract = v1_contract()
    local observed = v1_observation_for(contract.sessionID)
    local missing_directory = vim.deepcopy(contract.events.message)
    missing_directory.directory = nil

    assert.is_false(v1_observation.ingest_event(observed, missing_directory))
    assert.equals('error', observed:read().sync.messages.state)

    assert.matches('%[WARN%].*V1 observation diagnostic %(messages%): .* is missing directory', read_log())
  end)

  it('logs a warn entry when a V2 boundary diagnostic is recorded', function()
    local observed = v2_observation_for('ses-log-v2-diagnostic')

    assert.is_false(v2_observation.ingest_event(
      observed,
      v2_event('ses-log-v2-diagnostic', 'session.step.started', {
        agent = 'build',
        model = { providerID = 'p', id = 'm' },
      })
    ))
    assert.equals('error', observed:read().sync.messages.state)

    assert.matches(
      '%[WARN%].*V2 observation diagnostic %(messages%): session%.step%.started is missing assistant identity',
      read_log()
    )
  end)

  it('logs an unknown session event type only the first time', function()
    local observed = v2_observation_for('ses-log-unknown')

    for _ = 1, 3 do
      v2_events.route(observed._connection, v2_event('ses-log-unknown', 'session.foo.bar', { detail = 'x' }))
    end

    assert.equals(1, count_occurrences(read_log(), 'unhandled v2 event session%.foo%.bar is not in the contract'))
  end)

  it('does not log unknown events belonging to other sessions', function()
    local observed = v2_observation_for('ses-log-foreign')

    v2_events.route(observed._connection, v2_event('ses-foreign', 'session.foreign.only', { detail = 'x' }))

    assert.equals(0, count_occurrences(read_log(), 'unhandled v2 event session%.foreign%.only is not in the contract'))
  end)

  it('logs the session id when a resource snapshot request fails', function()
    local observed = v1_observation_for('ses-log-resource')
    local original = observed._runtime.request_resource
    observed._runtime.request_resource = function()
      error('snapshot unavailable')
    end

    observed:watch({ 'session' }, function() end)

    observed._runtime.request_resource = original
    assert.matches(
      '%[WARN%].*observation ses%-log%-resource load failed for session %([^%)]+%): .*snapshot unavailable',
      read_log()
    )
  end)

  it('does not log unknown events outside the session. prefix', function()
    local observed = v2_observation_for('ses-log-prefix')

    v2_events.route(observed._connection, v2_event('ses-log-prefix', 'other.unknown.event', { detail = 'x' }))

    assert.equals(0, count_occurrences(read_log(), 'unhandled v2 event other%.unknown%.event is not in the contract'))
  end)
end)
