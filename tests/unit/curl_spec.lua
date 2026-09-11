local curl = require('opencode.curl')

describe('curl stream handle lifecycle', function()
  local original_system

  before_each(function()
    original_system = vim.system
  end)

  after_each(function()
    vim.system = original_system
  end)

  it('parses the final response after informational and proxy headers', function()
    local response
    vim.system = function(_, _, cb)
      cb({
        code = 0,
        stdout = 'HTTP/1.1 200 Connection established\r\n\r\n'
          .. 'HTTP/1.1 100 Continue\r\nX-Interim: yes\r\n\r\n'
          .. 'HTTP/2 403 Forbidden\r\nContent-Type: application/json\r\n\r\n{"error":"denied"}',
      })
    end
    curl.request({
      url = 'https://example.test',
      callback = function(value)
        response = value
      end,
    })
    assert.equals(403, response.status)
    assert.equals('{"error":"denied"}', response.body)
    assert.same({ ['content-type'] = 'application/json' }, response.headers)
  end)

  it('preserves body text that resembles HTTP headers', function()
    local response
    vim.system = function(_, _, cb)
      cb({ code = 0, stdout = 'HTTP/1.1 200 OK\n\nHTTP/1.1 404 Not Found\n\nbody' })
    end
    curl.request({
      url = 'http://example.test',
      callback = function(value)
        response = value
      end,
    })
    assert.equals(200, response.status)
    assert.equals('HTTP/1.1 404 Not Found\n\nbody', response.body)
  end)

  it('preserves streaming lines across arbitrary chunk boundaries and EOF', function()
    local stdout, complete
    local lines = {}
    vim.system = function(_, opts, cb)
      stdout, complete = opts.stdout, cb
      return { pid = 123 }
    end
    curl.request({
      url = 'http://example.test/event',
      stream = function(_, line)
        lines[#lines + 1] = line
      end,
    })
    stdout(nil, 'one\ntw')
    stdout(nil, 'o\n\nthree\nfour')
    complete({ code = 0, signal = 0 })
    assert.same({ 'one\n', 'two\n', '\n', 'three\n', 'four' }, lines)
  end)

  it('marks stream handle as stopped after process exit', function()
    local on_complete

    vim.system = function(_, _, cb)
      on_complete = cb
      return {
        pid = 123,
        kill = function() end,
      }
    end

    local handle = curl.request({
      url = 'http://127.0.0.1:1/event',
      stream = function() end,
    })

    assert.is_true(handle.is_running())
    on_complete({ code = 0, signal = 0 })
    assert.is_false(handle.is_running())
  end)

  it('marks stream handle as stopped on shutdown', function()
    local killed = false
    local on_complete

    vim.system = function(_, _, cb)
      on_complete = cb
      return {
        pid = 123,
        kill = function()
          killed = true
        end,
      }
    end

    local handle = curl.request({
      url = 'http://127.0.0.1:1/event',
      stream = function() end,
    })

    handle.shutdown()
    on_complete({ code = 1, signal = 15 })

    assert.is_true(killed)
    assert.is_false(handle.is_running())
  end)

  it('reports whether stream exit followed an intentional shutdown', function()
    local on_complete
    local shutdown_requested

    vim.system = function(_, _, cb)
      on_complete = cb
      return { pid = 123, kill = function() end }
    end

    local handle = curl.request({
      url = 'http://127.0.0.1:1/event',
      stream = function() end,
      on_exit = function(_, _, requested)
        shutdown_requested = requested
      end,
    })

    handle.shutdown()
    on_complete({ code = 1, signal = 15 })

    assert.is_true(shutdown_requested)
  end)
end)
