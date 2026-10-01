local assert = require('luassert')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')
local base_picker = require('opencode.ui.base_picker')
local mcp_picker = require('opencode.ui.mcp_picker')
local server_job = require('opencode.server_job')
local transport = require('opencode.transport')

describe('opencode.ui.mcp_picker with V2 responses', function()
  local original_pick, original_request
  local captured_opts, servers, requests, notify

  before_each(function()
    original_pick = base_picker.pick
    original_request = transport.request
    captured_opts = nil
    servers = {
      { name = 'disabled', status = { status = 'disabled' } },
      { name = 'failed', status = { status = 'failed', error = 'Connection refused' } },
      { name = 'connected', status = { status = 'connected' } },
      { name = 'pending', status = { status = 'pending' } },
      { name = 'auth', status = { status = 'needs_auth', error = 'Sign in required' } },
    }
    requests = {}
    local connection = require('opencode.opencode_server').from_custom('http://v2.test')
    connection.protocol = 'v2'
    connection.server_identity = { version = '2.0.1' }
    connection.credential = { username = 'opencode' }
    connection:mark_ready()
    stub(server_job, 'ensure_server').returns(Promise.new():resolve(connection))
    notify = stub(vim, 'notify')
    base_picker.pick = function(opts)
      captured_opts = opts
      return true
    end
    transport.request = function(_, request)
      requests[#requests + 1] = request
      if request.method == 'GET' then
        return Promise.new():resolve({ status = 200, body = vim.json.encode({ data = servers }) })
      end
      for _, server in ipairs(servers) do
        if request.path == '/api/experimental/mcp/' .. server.name .. '/disconnect' then
          server.status = { status = 'disabled' }
        elseif request.path == '/api/experimental/mcp/' .. server.name .. '/connect' then
          server.status = { status = 'connected' }
        end
      end
      return Promise.new():resolve({ status = 204, body = '' })
    end
  end)

  after_each(function()
    base_picker.pick = original_pick
    transport.request = original_request
    server_job.ensure_server:revert()
    notify:revert()
  end)

  it('sorts string statuses and formats server names without passing array indices to nvim_strwidth', function()
    assert.is_true(mcp_picker.pick():wait())
    assert.equals('connected', captured_opts.items[1].name)
    assert.equals('failed', captured_opts.items[2].name)
    assert.equals('disabled', captured_opts.items[3].name)
    for _, item in ipairs(captured_opts.items) do
      local formatted = captured_opts.format_fn(item, 65)
      assert.truthy(formatted:to_string():find(item.name, 1, true))
    end
    assert.equals('OpencodeContextSwitchOn', captured_opts.format_fn(captured_opts.items[1], 65).parts[1].highlight)
    assert.equals('OpencodeContextError', captured_opts.format_fn(captured_opts.items[2], 65).parts[1].highlight)
    assert.equals('Connection refused', captured_opts.items[2].error)
  end)

  it('disconnects a connected server by name and reloads its status', function()
    mcp_picker.pick():wait()
    local updated = captured_opts.actions.toggle_connection.fn(captured_opts.items[1], {}):wait()
    assert.equals('/api/experimental/mcp/connected/disconnect', requests[2].path)
    assert.equals('GET', requests[3].method)
    local disconnected = vim.tbl_filter(function(item)
      return item.name == 'connected'
    end, updated)
    assert.equals(1, #disconnected)
    assert.equals('disabled', disconnected[1].status)
  end)

  it('connects a disabled server by name and reloads its status', function()
    mcp_picker.pick():wait()
    local updated = captured_opts.actions.toggle_connection.fn(captured_opts.items[3], {}):wait()
    assert.equals('/api/experimental/mcp/disabled/connect', requests[2].path)
    local connected = vim.tbl_filter(function(item)
      return item.name == 'disabled'
    end, updated)
    assert.equals(1, #connected)
    assert.equals('connected', connected[1].status)
  end)

  it('notifies instead of opening a picker when no MCP servers are configured', function()
    servers = {}
    mcp_picker.pick():wait()
    assert.is_nil(captured_opts)
    assert.stub(notify).was_called_with('No MCP servers configured', vim.log.levels.WARN)
  end)
end)
