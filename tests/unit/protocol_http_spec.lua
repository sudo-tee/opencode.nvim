local assert = require('luassert')
local http = require('opencode.protocols.http')
local Promise = require('opencode.promise')
local transport = require('opencode.transport')

describe('protocol HTTP helpers', function()
  local original_request

  before_each(function()
    original_request = transport.request
  end)

  after_each(function()
    transport.request = original_request
  end)

  it('encodes empty table request bodies as JSON objects', function()
    local captured
    transport.request = function(_, request)
      captured = request
      return Promise.new():resolve({ status = 200, headers = {}, body = '{}' })
    end

    local connection = { is_ready = function() return true end }
    http.json_request(connection, 'HTTP test', 'POST', '/test', nil, {}):wait()

    assert.equals('{}', captured.body)
  end)
end)
