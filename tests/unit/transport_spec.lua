local assert = require('luassert')
local curl = require('opencode.curl')
local transport = require('opencode.transport')

local function request_handle(options)
  local running = true
  return {
    is_running = function()
      return running
    end,
    shutdown = function()
      if not running then
        return
      end
      running = false
      if options and options.on_cancel then
        options.on_cancel()
      end
    end,
  }
end

local function connection(url, credential)
  local value = require('opencode.opencode_server').from_custom(url)
  value.protocol = 'v2'
  value.server_identity = { version = '2.0.1' }
  value.credential = credential or { username = 'opencode' }
  return value:mark_ready()
end

describe('transport', function()
  local original_request

  before_each(function()
    original_request = curl.request
  end)

  after_each(function()
    curl.request = original_request
  end)

  it('returns HTTP status, headers, and body bytes without decoding business data', function()
    local captured
    curl.request = function(options)
      captured = options
      vim.schedule(function()
        options.callback({ status = 202, headers = { ['content-type'] = 'application/json' }, body = '{"data":1}' })
      end)
      return request_handle(options)
    end
    local ready = connection('http://server.test/', { username = 'user', password = 'secret' })

    local response = transport
      .request(ready, {
        method = 'POST',
        path = '/api/session',
        query = 'directory=%2Fserver%2Fworkspace',
        body = '{"title":"demo"}',
      })
      :wait()

    assert.equals('http://server.test/api/session?directory=%2Fserver%2Fworkspace', captured.url)
    assert.equals('{"title":"demo"}', captured.body)
    assert.equals('Basic ' .. vim.base64.encode('user:secret'), captured.headers.Authorization)
    assert.same({ status = 202, headers = { ['content-type'] = 'application/json' }, body = '{"data":1}' }, response)
    assert.equals(0, vim.tbl_count(ready._requests))
  end)

  it('keeps Connection credentials isolated when responses complete out of order', function()
    local requests = {}
    curl.request = function(options)
      requests[#requests + 1] = options
      return request_handle(options)
    end
    local first = transport.request(connection('http://first.test', { username = 'first', password = 'one' }), {
      method = 'GET',
      path = '/api/config',
    })
    local second = transport.request(connection('http://second.test', { username = 'second', password = 'two' }), {
      method = 'GET',
      path = '/api/config',
    })

    assert.equals('Basic ' .. vim.base64.encode('first:one'), requests[1].headers.Authorization)
    assert.equals('Basic ' .. vim.base64.encode('second:two'), requests[2].headers.Authorization)
    requests[2].callback({ status = 200, body = 'second' })
    requests[1].callback({ status = 401, body = 'first' })
    assert.same({ status = 401, headers = {}, body = 'first' }, first:wait())
    assert.same({ status = 200, headers = {}, body = 'second' }, second:wait())
  end)

  it('rejects invalid requests before curl', function()
    local calls = 0
    curl.request = function()
      calls = calls + 1
    end
    local ready = connection('http://server.test')

    assert.is_false(pcall(transport.request, ready, { method = 'GET', path = '/api/session?x=1' }))
    assert.is_false(pcall(transport.request, ready, { method = 'PUT', path = '/api/session' }))
    ready:close():wait()
    assert.is_false(pcall(transport.request, ready, { method = 'GET', path = '/api/session' }))
    assert.equals(0, calls)
  end)

  it('streams bytes on the Connection and reports unexpected disconnect once', function()
    local captured
    local chunks, disconnects = {}, {}
    curl.request = function(options)
      captured = options
      return {
        shutdown = function() end,
        is_running = function()
          return true
        end,
      }
    end
    local ready = connection('http://server.test')
    local resource = transport.stream(ready, { method = 'GET', path = '/api/event' }, function(chunk)
      chunks[#chunks + 1] = chunk
    end, function(reason)
      disconnects[#disconnects + 1] = reason
    end)

    captured.stream(nil, 'data: one\n')
    assert.equals(resource, ready._stream)
    captured.on_error({ message = 'connection reset' })
    captured.on_exit(56, 0, false)

    assert.same({}, chunks)
    assert.same({}, disconnects)
    assert.equals(resource, ready._stream)
    assert.is_true(vim.wait(100, function()
      return #chunks == 1 and #disconnects == 1 and ready._stream == nil
    end))
    assert.same({ 'data: one\n' }, chunks)
    assert.equals(1, #disconnects)
    assert.equals('connection reset', disconnects[1].message)
    assert.is_nil(ready._stream)
  end)

  it('does not let a late stream exit clear a replacement stream', function()
    local requests = {}
    curl.request = function(options)
      requests[#requests + 1] = options
      return {
        shutdown = function() end,
        is_running = function()
          return true
        end,
      }
    end
    local ready = connection('http://server.test')
    local first = transport.stream(ready, { method = 'GET', path = '/api/first' }, function() end)
    ready:set_stream(nil)
    local second = transport.stream(ready, { method = 'GET', path = '/api/second' }, function() end)

    requests[1].on_exit(0, 0, true)
    assert.equals(second, ready._stream)
    requests[2].on_exit(0, 0, true)
    assert.equals(second, ready._stream)
    assert.is_true(vim.wait(100, function()
      return ready._stream == nil
    end))
    assert.is_nil(ready._stream)
    assert.not_equals(first, second)
  end)

  it('cancels every pending HTTP request when its Connection closes', function()
    local requests = {}
    local shutdowns = 0
    curl.request = function(options)
      requests[#requests + 1] = options
      local handle = request_handle(options)
      local shutdown = handle.shutdown
      handle.shutdown = function()
        if handle.is_running() then
          shutdowns = shutdowns + 1
        end
        shutdown()
      end
      return handle
    end
    local ready = connection('http://server.test')
    local first = transport.request(ready, { method = 'GET', path = '/api/config' })
    local second = transport.request(ready, { method = 'GET', path = '/api/session' })

    assert.equals(2, vim.tbl_count(ready._requests))
    ready:close():wait()

    local first_ok, first_err = pcall(first.wait, first)
    local second_ok, second_err = pcall(second.wait, second)
    assert.is_false(first_ok)
    assert.is_false(second_ok)
    assert.equals('HTTP request cancelled', first_err)
    assert.equals('HTTP request cancelled', second_err)
    assert.equals(2, shutdowns)
    assert.equals(0, vim.tbl_count(ready._requests))

    requests[1].callback({ status = 200, body = 'late first' })
    requests[2].callback({ status = 200, body = 'late second' })
    assert.is_true(first:is_rejected())
    assert.is_true(second:is_rejected())
    assert.is_nil(first:peek())
    assert.is_nil(second:peek())
  end)
end)
