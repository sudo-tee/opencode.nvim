local api_client = require('opencode.api_client')
local config = require('opencode.config')
local assert = require('luassert')

describe('api_client', function()
  it('should create a new client instance', function()
    local client = api_client.new('http://localhost:8080')
    assert.is_not_nil(client)
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should remove trailing slash from base_url', function()
    local client = api_client.new('http://localhost:8080/')
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should create client using create factory function', function()
    local client = api_client.create('http://localhost:8080')
    assert.is_not_nil(client)
    assert.are.equal('http://localhost:8080', client.base_url)
  end)

  it('should have all expected API methods', function()
    local client = api_client.new('http://localhost:8080')

    -- Project endpoints
    assert.is_function(client.list_projects)
    assert.is_function(client.get_current_project)

    -- Config endpoints
    assert.is_function(client.get_config)
    assert.is_function(client.update_config)
    assert.is_function(client.list_providers)

    -- Session endpoints
    assert.is_function(client.list_sessions)
    assert.is_function(client.create_session)
    assert.is_function(client.get_session)
    assert.is_function(client.delete_session)
    assert.is_function(client.update_session)
    assert.is_function(client.get_session_children)

    -- Message endpoints
    assert.is_function(client.list_messages)
    assert.is_function(client.create_message)
    assert.is_function(client.get_message)

    -- Find endpoints
    assert.is_function(client.find_text)
    assert.is_function(client.find_files)
    assert.is_function(client.find_symbols)

    -- File endpoints
    assert.is_function(client.list_files)
    assert.is_function(client.read_file)
    assert.is_function(client.get_file_status)

    -- Event endpoints
    assert.is_function(client.subscribe_to_events)
  end)

  it('should construct URLs correctly with query parameters', function()
    local server_job = require('opencode.server_job')
    local original_call_api = server_job.call_api
    local captured_calls = {}
    local original_cwd = vim.fn.getcwd
    local state = require('opencode.state')
    state.current_cwd = '/current/directory'

    vim.fn.getcwd = function()
      return '/current/directory'
    end

    server_job.call_api = function(url, method, body)
      table.insert(captured_calls, { url = url, method = method, body = body })
      local promise = require('opencode.promise').new()
      promise:resolve({})
      return promise
    end

    local client = api_client.new('http://localhost:8080')

    -- Test without query params
    client:list_projects()
    assert.are.equal('http://localhost:8080/project?directory=%2Fcurrent%2Fdirectory', captured_calls[1].url)
    assert.are.equal('GET', captured_calls[1].method)

    -- Test with query params
    client:list_projects('/some/directory')
    assert.are.equal('http://localhost:8080/project?directory=%2Fsome%2Fdirectory', captured_calls[2].url)

    -- Test with multiple query params
    client:list_tools('anthropic', 'claude-3', '/some/dir')
    local actual_url = captured_calls[3].url

    -- Check base URL and endpoint
    assert.is_true(actual_url:find('http://localhost:8080/experimental/tool?') == 1)

    -- Check that all expected parameters are present (order doesn't matter)
    assert.is_not_nil(actual_url:find('provider=anthropic'))
    assert.is_not_nil(actual_url:find('model=claude%-3')) -- Escape the dash
    assert.is_not_nil(actual_url:find('directory=%%2Fsome%%2Fdir'))

    -- Restore original function
    server_job.call_api = original_call_api
    vim.fn.getcwd = original_cwd
  end)

  it('maps outbound query paths using runtime to_server transform', function()
    local server_job = require('opencode.server_job')
    local original_call_api = server_job.call_api
    local original_runtime = vim.deepcopy(config.runtime)
    config.runtime.path.to_server = function(path)
      local normalized = path:gsub('\\', '/')
      local drive, rest = normalized:match('^(%a):(/.*)$')
      if drive then
        return string.format('/mnt/%s%s', drive:lower(), rest)
      end
      return normalized
    end

    local captured_call = nil
    server_job.call_api = function(url, method, body)
      captured_call = { url = url, method = method, body = body }
      local promise = require('opencode.promise').new()
      promise:resolve({})
      return promise
    end

    local client = api_client.new('http://localhost:8080')
    client:list_files('C:\\Users\\me\\repo\\main.lua', 'C:\\Users\\me\\repo')

    assert.is_not_nil(captured_call)
    assert.are.equal('GET', captured_call.method)
    assert.is_not_nil(
      captured_call.url:find('path=%2Fmnt%2Fc%2FUsers%2Fme%2Frepo%2Fmain.lua', 1, true)
    )
    assert.is_not_nil(captured_call.url:find('directory=%2Fmnt%2Fc%2FUsers%2Fme%2Frepo', 1, true))

    config.runtime = original_runtime
    server_job.call_api = original_call_api
  end)

  it('maps event subscription directory using runtime to_server transform', function()
    local server_job = require('opencode.server_job')
    local original_stream_api = server_job.stream_api
    local original_runtime = vim.deepcopy(config.runtime)
    config.runtime.path.to_server = function(path)
      local normalized = path:gsub('\\', '/')
      local drive, rest = normalized:match('^(%a):(/.*)$')
      if drive then
        return string.format('/mnt/%s%s', drive:lower(), rest)
      end
      return normalized
    end

    local captured_url = nil
    server_job.stream_api = function(url)
      captured_url = url
      return {}
    end

    local client = api_client.new('http://localhost:8080')
    client:subscribe_to_events('C:\\Users\\me\\repo', function() end)

    assert.are.equal(
      'http://localhost:8080/event?directory=%2Fmnt%2Fc%2FUsers%2Fme%2Frepo',
      captured_url
    )

    config.runtime = original_runtime
    server_job.stream_api = original_stream_api
  end)
end)
