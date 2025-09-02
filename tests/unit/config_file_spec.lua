local config_file = require('opencode.config_file')
local assert = require('luassert')

describe('config_file.setup', function()
  local original_run_server_api
  local original_with_server
  local base_url = 'http://localhost:1234'
  local original_notify
  local _notifications = {}

  before_each(function()
    _notifications = {}
    original_notify = vim.notify
    config_file.config_cache = nil
    local core = require('opencode.core')
    local server_job = require('opencode.server_job')
    original_run_server_api = core.run_server_api
    original_with_server = server_job.with_server
    -- Set up mock immediately to prevent any real API calls
    server_job.with_server = function(callback)
      vim.schedule(function()
        callback({
          shutdown = function() end,
        }, base_url)
      end)
    end
    vim.notify = function(msg, level)
      table.insert(_notifications, { msg = msg, level = level })
    end
  end)

  after_each(function()
    vim.notify = original_notify
    if original_run_server_api then
      local core = require('opencode.core')
      core.run_server_api = original_run_server_api
    end

    if original_with_server then
      local server_job = require('opencode.server_job')
      server_job.with_server = original_with_server
    end
    config_file.config_cache = nil
  end)

  it('calls core.run_server_api with correct parameters', function()
    local server_job = require('opencode.server_job')
    local api_calls = {}

    server_job.call_api = function(url, method, body, cb)
      table.insert(api_calls, {
        url = url,
        method = method,
        body = body,
      })
      cb(nil, {})
    end

    config_file.setup()

    vim.wait(10)

    assert.are.equal(2, #api_calls)
    assert.are.equal(base_url .. '/config', api_calls[1].url)
    assert.are.equal('GET', api_calls[1].method)
    assert.is_nil(api_calls[1].body)
  end)

  it('caches response on successful API call', function()
    local server_job = require('opencode.server_job')
    local test_config = { agent = { ['test-agent'] = {} } }

    server_job.call_api = function(url, method, body, cb)
      if url:find('/config') then
        cb(nil, test_config)
        return
      end
      if url:find('/project/current') then
        cb(nil, { name = 'Test Project' })
        return
      end
    end

    config_file.setup()

    vim.wait(50)

    assert.are.same(test_config, config_file.config_cache)
  end)

  it('handles API error correctly', function()
    local server_job = require('opencode.server_job')

    server_job.call_api = function(url, method, body, cb)
      vim.schedule(function()
        cb('Server error', nil)
      end)
    end

    config_file.setup()

    vim.wait(50)

    assert.are.equal(2, #_notifications)
    assert.is_not_nil(string.find(_notifications[1].msg, 'Error fetching config file from server'))
    assert.are.equal(vim.log.levels.ERROR, _notifications[1].level)
    assert.is_nil(config_file.config_cache)
  end)
end)

describe('config_file.get_opencode_agents', function()
  before_each(function()
    config_file.config_cache = nil
  end)

  after_each(function()
    config_file.config_cache = nil
  end)

  it('returns empty table when no config is cached', function()
    local agents = config_file.get_opencode_agents()
    assert.are.same({}, agents)
  end)

  it('returns agents from cached config', function()
    config_file.config_cache = {
      agent = {
        ['custom-agent'] = {},
        ['another-agent'] = {},
      },
    }

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'custom-agent'))
    assert.True(vim.tbl_contains(agents, 'another-agent'))
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)

  it('includes default build and plan agents', function()
    config_file.config_cache = {}

    local agents = config_file.get_opencode_agents()
    assert.True(vim.tbl_contains(agents, 'build'))
    assert.True(vim.tbl_contains(agents, 'plan'))
  end)
end)
