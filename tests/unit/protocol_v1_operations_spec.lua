local assert = require('luassert')
local operations = require('opencode.protocols.v1.operations')
local Promise = require('opencode.promise')
local transport = require('opencode.transport')
local url_encode = require('opencode.util').url_encode

local function ready_connection(url)
  local connection = require('opencode.opencode_server').from_custom(url or 'http://v1.test')
  connection.protocol = 'v1'
  connection.server_identity = { version = '1.18.30' }
  connection.credential = { username = 'opencode' }
  return connection:mark_ready()
end

local function fixture()
  local path = vim.fn.getcwd() .. '/tests/data/v1/operations.json'
  return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
end

local function encoded_query(values)
  local keys = vim.tbl_keys(values)
  table.sort(keys)
  local result = {}
  for _, key in ipairs(keys) do
    result[#result + 1] = url_encode(key) .. '=' .. url_encode(tostring(values[key]))
  end
  return #result > 0 and table.concat(result, '&') or nil
end

describe('V1 protocol operations', function()
  local original_request, original_stream

  before_each(function()
    original_request = transport.request
    original_stream = transport.stream
  end)

  after_each(function()
    transport.request = original_request
    transport.stream = original_stream
  end)

  it('binds the native operation table when the Connection becomes ready', function()
    local connection = ready_connection()
    assert.equals(operations, connection.operations)
    assert.is_nil(connection.operations.list_models)
    assert.is_nil(connection.operations.get_default_model)
  end)

  it('uses the fixed V1 native paths, query, body, and direct response contracts', function()
    local contracts = fixture()
    local connection = ready_connection()
    local location = { directory = '/host/workspace' }
    local function to_server(path)
      return path:gsub('^/host', '/server')
    end
    local function to_host(path)
      return path:gsub('^/server', '/host')
    end
    local calls = {}
    local active_name
    transport.request = function(passed_connection, request)
      calls[#calls + 1] = { connection = passed_connection, request = request }
      local contract = contracts[active_name]
      return Promise.new():resolve({ status = 200, headers = {}, body = vim.json.encode(contract.response) })
    end

    local cases = {
      get_config = function()
        return operations.get_config(connection, location, to_server, to_host):wait()
      end,
      list_providers = function()
        return operations.list_providers(connection, location, to_server, to_host):wait()
      end,
      get_current_project = function()
        return operations.get_current_project(connection, location, to_server, to_host):wait()
      end,
      list_sessions = function()
        return operations.list_sessions(connection, location, 20, to_server, to_host):wait()
      end,
      list_session_status = function()
        return operations.list_session_status(connection, location, to_server, to_host):wait()
      end,
      list_sessions_global = function()
        return operations.list_sessions_global(connection, to_host):wait()
      end,
      create_session = function()
        return operations.create_session(connection, location, { title = 'New' }, to_server, to_host):wait()
      end,
      get_session = function()
        return operations.get_session(connection, 'ses-1', location, to_server, to_host):wait()
      end,
      delete_session = function()
        return operations.delete_session(connection, 'ses-1', location, to_server):wait()
      end,
      rename_session = function()
        return operations
          .rename_session(connection, 'ses-1', location, 'Renamed', to_server, to_host)
          :wait()
      end,
      list_children = function()
        return operations.list_children(connection, 'ses-1', location, to_server, to_host):wait()
      end,
      init_session = function()
        return operations
          .init_session(connection, 'ses-1', location, {
            messageID = 'msg-1',
            providerID = 'provider',
            modelID = 'model',
          }, to_server)
          :wait()
      end,
      share_session = function()
        return operations.share_session(connection, 'ses-1', location, to_server, to_host):wait()
      end,
      unshare_session = function()
        return operations.unshare_session(connection, 'ses-1', location, to_server, to_host):wait()
      end,
      summarize_session = function()
        return operations
          .summarize_session(connection, 'ses-1', location, { providerID = 'provider', modelID = 'model' }, to_server)
          :wait()
      end,
      fork_session = function()
        return operations
          .fork_session(connection, 'ses-1', location, { messageID = 'msg-1' }, to_server, to_host)
          :wait()
      end,
      list_messages = function()
        return operations.list_messages(connection, 'ses-1', location, 20, nil, to_server, to_host):wait()
      end,
      submit = function()
        return operations
          .submit(connection, 'ses-1', location, { parts = { { type = 'text', text = 'hello' } } }, to_server, to_host)
          :wait()
      end,
      send_command = function()
        return operations
          .send_command(connection, 'ses-1', location, { command = 'test', arguments = 'arg' }, to_server, to_host)
          :wait()
      end,
      revert_message = function()
        return operations
          .revert_message(connection, 'ses-1', location, { messageID = 'msg-1' }, to_server, to_host)
          :wait()
      end,
      unrevert_messages = function()
        return operations.unrevert_messages(connection, 'ses-1', location, to_server, to_host):wait()
      end,
      interrupt = function()
        return operations.interrupt(connection, 'ses-1', location, to_server):wait()
      end,
      list_permissions = function()
        return operations.list_permissions(connection, location, to_server, to_host):wait()
      end,
      reply_permission = function()
        return operations.reply_permission(connection, 'per-1', location, { reply = 'once' }, to_server):wait()
      end,
      list_questions = function()
        return operations.list_questions(connection, location, to_server, to_host):wait()
      end,
      reply_question = function()
        return operations.reply_question(connection, 'que-1', location, { { 'A' } }, to_server):wait()
      end,
      reject_question = function()
        return operations.reject_question(connection, 'que-1', location, to_server):wait()
      end,
      list_commands = function()
        return operations.list_commands(connection, location, to_server, to_host):wait()
      end,
      find_files = function()
        return operations.find_files(connection, 'main', location, to_server, to_host):wait()
      end,
      get_file_status = function()
        return operations.get_file_status(connection, location, to_server, to_host):wait()
      end,
      list_agents = function()
        return operations.list_agents(connection, location, to_server, to_host):wait()
      end,
      list_skills = function()
        return operations.list_skills(connection, location, to_server, to_host):wait()
      end,
      list_mcp_servers = function()
        return operations.list_mcp_servers(connection, location, to_server, to_host):wait()
      end,
      connect_mcp = function()
        return operations.connect_mcp(connection, 'test', location, to_server):wait()
      end,
      disconnect_mcp = function()
        return operations.disconnect_mcp(connection, 'test', location, to_server):wait()
      end,
    }

    for name, invoke in pairs(cases) do
      active_name = name
      local result = invoke()
      local captured = calls[#calls]
      local contract = contracts[name]
      assert.equals(connection, captured.connection)
      assert.equals(contract.method, captured.request.method)
      assert.equals(contract.path, captured.request.path)
      assert.equals(encoded_query(contract.query), captured.request.query)
      if contract.body then
        assert.same(contract.body, vim.json.decode(captured.request.body))
      else
        assert.is_nil(captured.request.body)
      end
      if name == 'get_current_project' or name == 'create_session' or name == 'get_session' then
        assert.equals('/host/workspace', result.directory or result.worktree)
      elseif name == 'find_files' then
        assert.equals('/host/workspace/main.lua', result[1])
      end
    end
  end)

  it('interprets V1 config resources inside the V1 protocol', function()
    local config = {
      agent = {
        custom = { mode = 'primary' },
        shared = { mode = 'all' },
        helper = { mode = 'subagent' },
        build = { disable = true },
        explore = { hidden = true },
        general = { disable = true },
      },
      command = { review = { template = 'review $ARGUMENTS' } },
    }
    transport.request = function(_, request)
      local body = request.path == '/config/providers' and { providers = {}, default = {} } or config
      return Promise.new():resolve({ status = 200, body = vim.json.encode(body) })
    end
    local connection = ready_connection()
    local location = { directory = '/workspace' }

    assert.same({ providers = {}, default = {} }, operations.get_model_catalog(connection, location):wait())
    assert.same({ 'plan', 'custom', 'shared' }, operations.list_primary_agents(connection, location):wait())
    assert.same({ 'helper', 'shared' }, operations.list_subagents(connection, location):wait())
    assert.same(config.command, operations.get_user_commands(connection, location):wait())
  end)

  it('preserves the captured location and Connection across interleaved responses', function()
    local pending = {}
    transport.request = function(connection, request)
      local promise = Promise.new()
      pending[#pending + 1] = { connection = connection, request = request, promise = promise }
      return promise
    end
    local first = operations.list_sessions(ready_connection('http://first.test'), { directory = '/one' })
    local second = operations.list_sessions(ready_connection('http://second.test'), { directory = '/two' })

    assert.equals('directory=%2Fone', pending[1].request.query)
    assert.equals('directory=%2Ftwo', pending[2].request.query)
    pending[2].promise:resolve({ status = 200, body = '[{"id":"second"}]' })
    pending[1].promise:resolve({ status = 200, body = '[{"id":"first"}]' })
    assert.equals('first', first:wait()[1].id)
    assert.equals('second', second:wait()[1].id)
  end)

  it('exposes HTTP status and invalid JSON at the operation boundary', function()
    local responses = {
      { status = 401, body = '{"error":"auth"}' },
      { status = 404, body = '{"error":"missing"}' },
      { status = 500, body = '{"error":"boom"}' },
      { status = 200, body = '<html>' },
    }
    local calls = 0
    transport.request = function()
      calls = calls + 1
      return Promise.new():resolve(responses[calls])
    end

    for index = 1, #responses do
      local ok, err = pcall(function()
        operations.get_config(ready_connection(), { directory = '/workspace' }):wait()
      end)
      assert.is_false(ok)
      if responses[index].status == 200 then
        assert.matches('invalid JSON', tostring(err))
      else
        assert.matches('HTTP ' .. responses[index].status, tostring(err))
      end
    end
  end)

  it('builds the V1 event stream without interpreting SSE bytes', function()
    local captured
    transport.stream = function(connection, request, on_chunk, on_disconnect)
      captured = { connection = connection, request = request, on_chunk = on_chunk, on_disconnect = on_disconnect }
      return { shutdown = function() end }
    end
    local connection = ready_connection()
    local chunks = {}
    operations.subscribe_events(connection, function(chunk)
      chunks[#chunks + 1] = chunk
    end)

    captured.on_chunk('data: {"payload":{}}\n\n')
    assert.equals(connection, captured.connection)
    assert.same({ method = 'GET', path = '/global/event' }, captured.request)
    assert.same({ 'data: {"payload":{}}\n\n' }, chunks)
  end)
end)
