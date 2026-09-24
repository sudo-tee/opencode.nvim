local operations = require('opencode.protocols.v2.operations')
local contract_check = require('opencode.protocols.contract_check')
local transport = require('opencode.transport')
local log = require('opencode.log')
local stub = require('luassert.stub')
local Promise = require('opencode.promise')

local function fixture(name)
  local path = vim.fn.getcwd() .. '/tests/data/v2/' .. name
  return table.concat(vim.fn.readfile(path), '\n')
end

describe('V2 operations contract', function()
  it('only names endpoints the opencode 2.0.14 server declares', function()
    local spec = vim.json.decode(fixture('openapi.json'))
    local offered = spec.paths
    assert.is_truthy(type(offered) == 'table' and next(offered), 'fixture must carry openapi paths')

    for _, entry in ipairs(operations.contract) do
      local method, path = entry[1], entry[2]
      assert.truthy(
        type(offered[path]) == 'table' and offered[path][method:lower()] ~= nil,
        ('contract entry %s %s is missing from the 2.0.14 openapi fixture'):format(method, path)
      )
    end
  end)

  it('reports contract endpoints the live server lacks', function()
    stub(transport, 'request').invokes(function(_, request)
      assert.equals('/openapi.json', request.path)
      return Promise.new():resolve({ status = 200, body = '{"paths":{"/api/session":{"get":{},"post":{},"patch":{},"delete":{}}}}' })
    end)
    local warned = stub(log, 'warn').invokes(function() end)

    local connection = { protocol = 'v2', version = '2.0.14' }
    local missing = contract_check.check(connection):wait()

    assert.truthy(#missing >= 33, 'most endpoints must be reported missing')
    assert.truthy(vim.tbl_contains(missing, 'POST /api/session/{sessionID}/prompt'))
    assert.falsy(vim.tbl_contains(missing, 'GET /api/session'))
    assert.stub(warned).was_called_with('opencode %s API drift: server openapi lacks %d endpoint(s) used by this plugin: %s', '2.0.14', #missing, table.concat(missing, ', '))

    transport.request:revert()
    log.warn:revert()
  end)

  it('points plugin updates at a server newer than the anchor and CLI updates at an older one', function()
    local notifications = {}
    stub(vim, 'notify').invokes(function(msg, level, opts)
      notifications[#notifications + 1] = { msg = msg, level = level, opts = opts }
    end)

    contract_check.notify_drift('2.1.0', 2)
    contract_check.notify_drift('2.0.9', 1)
    contract_check.notify_drift(nil, 3)

    assert.matches('update this plugin to match your opencode 2%.1%.0', notifications[1].msg)
    assert.equals(vim.log.levels.WARN, notifications[1].level)
    assert.equals('opencode.nvim', notifications[1].opts.title)
    assert.matches('update the opencode CLI to match this plugin', notifications[2].msg)
    assert.matches('so versions match', notifications[3].msg)

    vim.notify:revert()
  end)

  it('skips the check quietly when the server does not answer with an openapi document', function()
    stub(transport, 'request').invokes(function()
      return Promise.new():reject({ kind = 'transport', cause = 'refused' })
    end)
    local warned = stub(log, 'warn').invokes(function() end)

    assert.is_nil(contract_check.check({ protocol = 'v2', version = '2.0.14' }):wait())
    assert.stub(warned).was_not_called()

    transport.request:revert()
    log.warn:revert()
  end)

  it('does not run for frozen V1 servers', function()
    stub(transport, 'request').invokes(function()
      error('V1 servers must not be probed for drift', 0)
    end)

    contract_check.check_async({ protocol = 'v1', version = '1.18.30' })
    vim.wait(50, function() return false end)

    transport.request:revert()
  end)
end)
