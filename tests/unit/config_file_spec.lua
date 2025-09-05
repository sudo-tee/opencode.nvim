local config_file = require('opencode.config_file')
local Promise = require('opencode.promise')
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
    config_file.config_promise = nil
    config_file.project_promise = nil
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

    server_job.call_api = function(url, method, body)
      table.insert(api_calls, {
        url = url,
        method = method,
        body = body,
      })
      return Promise.new():resolve({})
    end

    config_file.setup()

    vim.wait(10)

    assert.are.equal(2, #api_calls)
    assert.are.equal(base_url .. '/config', api_calls[1].url)
    assert.are.equal('GET', api_calls[1].method)
    assert.is_nil(api_calls[1].body)
  end)

  it('caches resolved response on successful API call', function()
    local server_job = require('opencode.server_job')
    local test_config = { agent = { ['test-agent'] = {} } }

    server_job.call_api = function(url, method, body)
      if url:find('/config') then
        return Promise.new():resolve(test_config)
      end
      if url:find('/project/current') then
        return Promise.new():resolve({ name = 'Test Project' })
      end
    end

    config_file.setup()

    vim.wait(50)

    assert.are.equal(test_config, config_file.config_promise:wait())
  end)

  it('handles API error correctly', function()
    local server_job = require('opencode.server_job')

    server_job.call_api = function(url, method, body)
      return Promise.new():reject('Server error')
    end

    config_file.setup()

    vim.wait(50)

    assert.are.equal(2, #_notifications)
    assert.is_not_nil(string.find(_notifications[1].msg, 'Error fetching config file from server'))
    assert.are.equal(vim.log.levels.ERROR, _notifications[1].level)
    assert.is_nil(config_file.config_cache)
  end)

  describe('config_file.get_opencode_agents', function()
    it('returns agents from config', function()
      local server_job = require('opencode.server_job')
      server_job.call_api = function(url, method, body)
        if url:find('/config') then
          return Promise.new():resolve({ agent = { ['custom-agent'] = {}, ['another-agent'] = {} } })
        end
        if url:find('/project/current') then
          return Promise.new():resolve({ name = 'Test Project' })
        end
      end

      config_file.setup()
      vim.wait(50)

      local agents = config_file.get_opencode_agents()
      assert.True(vim.tbl_contains(agents, 'custom-agent'))
      assert.True(vim.tbl_contains(agents, 'another-agent'))
      assert.True(vim.tbl_contains(agents, 'build'))
      assert.True(vim.tbl_contains(agents, 'plan'))
    end)
  end)
end)
