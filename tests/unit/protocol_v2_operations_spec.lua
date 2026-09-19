local assert = require('luassert')
local operations = require('opencode.protocols.v2.operations')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local transport = require('opencode.transport')

local function ready_connection(url)
  local connection = require('opencode.opencode_server').from_custom(url or 'http://v2.test')
  connection.protocol = 'v2'
  connection.server_identity = { version = '2.0.1' }
  connection.credential = { username = 'opencode' }
  return connection:mark_ready()
end

local function fixture(name)
  local path = vim.fn.getcwd() .. '/tests/data/v2/' .. name
  return table.concat(vim.fn.readfile(path), '\n')
end

describe('V2 protocol operations', function()
  local original_request, original_stream, original_cwd

  before_each(function()
    original_request = transport.request
    original_stream = transport.stream
    original_cwd = state.current_cwd
  end)

  after_each(function()
    transport.request = original_request
    transport.stream = original_stream
    state.context.set_current_cwd(original_cwd)
  end)

  it('binds the native operation table when the Connection becomes ready', function()
    local connection = ready_connection()
    assert.equals(operations, connection.operations)
    assert.is_nil(connection.operations.list_children)
    assert.equals(operations.list_sessions_global, connection.operations.list_sessions_global)
    assert.equals(operations.init_session, connection.operations.init_session)
    assert.equals(operations.share_session, connection.operations.share_session)
    assert.equals(operations.summarize_session, connection.operations.summarize_session)
    assert.equals(operations.fork_session, connection.operations.fork_session)
    assert.equals(operations.revert_message, connection.operations.revert_message)
  end)

  it('uses direct, location/data, and page response contracts from the V2 fixtures', function()
    local bodies = {
      ['/api/config'] = fixture('config.json'),
      ['/api/location'] = fixture('location.json'),
      ['/api/provider'] = fixture('provider.json'),
      ['/api/session'] = fixture('session.json'),
    }
    local calls = {}
    transport.request = function(connection, request)
      calls[#calls + 1] = { connection = connection, request = request }
      return Promise.new():resolve({ status = 200, headers = {}, body = bodies[request.path] })
    end
    local connection = ready_connection()
    local location = { directory = '/host/workspace' }
    local function to_server(path)
      return path:gsub('^/host', '/server')
    end
    local function to_host(path)
      return path:gsub('^/Users/oujinsai', '/host')
    end

    local config = operations.get_config(connection, location, to_server, to_host):wait()
    local project = operations.get_current_project(connection, location, to_server, to_host):wait()
    local providers = operations.list_providers(connection, location, to_server, to_host):wait()
    local sessions = operations.list_sessions(connection, location, nil, 25, to_server, to_host):wait()
    local provider_fixture = vim.json.decode(bodies['/api/provider'])
    local session_fixture = vim.json.decode(bodies['/api/session'])

    assert.equals('/host/.claude', config[1].path)
    assert.equals('/host/Projects/nvim-plugins/opencode.nvim', project.directory)
    assert.same(provider_fixture.location, providers.location)
    assert.same(provider_fixture.data, providers.data)
    assert.equals(to_host(session_fixture.data[1].location.directory), sessions.data[1].location.directory)
    assert.truthy(sessions.cursor.next)
    assert.equals('location.directory=%2Fserver%2Fworkspace', calls[1].request.query)
    assert.equals('location.directory=%2Fserver%2Fworkspace', calls[2].request.query)
    assert.equals('location.directory=%2Fserver%2Fworkspace', calls[3].request.query)
    assert.equals('directory=%2Fserver%2Fworkspace&limit=25', calls[4].request.query)
  end)

  it('extracts the project object from the location envelope without unwrapping its data field', function()
    transport.request = function()
      return Promise.new():resolve({
        status = 200,
        body = '{"directory":"/server/project","project":{"id":"project","directory":"/server/project","data":{"belongs":"to-project"}}}',
      })
    end
    local result = operations
      .get_current_project(ready_connection(), { directory = '/server/project' }, nil, function(path)
        return path:gsub('^/server', '/host')
      end)
      :wait()

    assert.equals('project', result.id)
    assert.same({ belongs = 'to-project' }, result.data)
    assert.equals('/host/project', result.directory)
  end)

  it('does not unwrap a data field from a direct array response', function()
    transport.request = function()
      return Promise.new():resolve({
        status = 200,
        body = '[{"data":{"belongs":"to-source"},"path":"/server/config.json"}]',
      })
    end
    local result = operations
      .get_config(ready_connection(), { directory = '/server/project' }, nil, function(path)
        return path:gsub('^/server', '/host')
      end)
      :wait()

    assert.same({ belongs = 'to-source' }, result[1].data)
    assert.equals('/host/config.json', result[1].path)
  end)

  it('maps business data without changing a provider envelope location', function()
    transport.request = function()
      return Promise.new():resolve({
        status = 200,
        body = '{"location":{"directory":"/server/location"},"data":{"path":"/server/data"}}',
      })
    end
    local result = operations
      .list_providers(ready_connection(), { directory = '/server/request' }, nil, function(path)
        return path:gsub('^/server', '/host')
      end)
      :wait()

    assert.equals('/server/location', result.location.directory)
    assert.equals('/host/data', result.data.path)
  end)

  it('builds native session, message, setting, submit, and interrupt requests', function()
    local calls = {}
    transport.request = function(connection, request)
      calls[#calls + 1] = { connection = connection, request = request }
      if request.path:match('/agent$') or request.path:match('/model$') then
        return Promise.new():resolve({ status = 204, body = '' })
      end
      if request.path:match('/interrupt$') then
        return Promise.new():resolve({ status = 200, body = '{"interrupted":true}' })
      end
      if request.path:match('/message$') then
        return Promise.new():resolve({ status = 200, body = '{"data":[{"id":"msg-1"}],"cursor":{"next":"c2"}}' })
      end
      if request.path:match('/prompt$') then
        return Promise.new():resolve({ status = 200, body = '{"data":{"id":"inbox-1","delivery":"steer"}}' })
      end
      return Promise.new()
        :resolve({ status = 200, body = '{"data":{"id":"ses-1","location":{"directory":"/server/project"}}}' })
    end
    local connection = ready_connection()
    local function to_server(path)
      assert.is_nil(path:match('^/server'), 'path mapping must run once')
      return path:gsub('^/host', '/server')
    end
    local function to_host(path)
      return path:gsub('^/server', '/host')
    end

    local created = operations
      .create_session(connection, { directory = '/host/project' }, { title = 'New' }, to_server, to_host)
      :wait()
    local session = operations.get_session(connection, 'ses-1', nil, nil, to_host):wait()
    local page = operations.list_messages(connection, 'ses-1', 'c1', 20, to_host):wait()
    operations.set_session_agent(connection, 'ses-1', 'build'):wait()
    operations
      .set_session_model(connection, 'ses-1', {
        providerID = 'provider',
        id = 'model',
        variant = 'high',
      })
      :wait()
    local admission = operations
      .submit(connection, 'ses-1', {
        text = 'hello @main.lua',
        context = { { text = 'selected', source = { kind = 'selection', file_name = 'main.lua', range = '1-2' } } },
        files = {
          {
            server_uri = 'file:///host/project/main.lua',
            media_type = 'text/plain',
            name = 'main.lua',
            mention = { start_byte = 6, end_byte = 15 },
          },
        },
        agents = {},
      }, to_server, to_host)
      :wait()
    local interrupted = operations.interrupt(connection, 'ses-1'):wait()

    assert.equals('/host/project', created.location.directory)
    assert.equals('/host/project', session.location.directory)
    assert.equals('c2', page.cursor.next)
    assert.equals('inbox-1', admission.id)
    assert.is_true(interrupted)
    assert.same({ location = { directory = '/server/project' }, title = 'New' }, vim.json.decode(calls[1].request.body))
    assert.is_nil(calls[2].request.query)
    assert.equals('cursor=c1&limit=20', calls[3].request.query)
    assert.equals('/api/session/ses-1/agent', calls[4].request.path)
    assert.same({ agent = 'build' }, vim.json.decode(calls[4].request.body))
    assert.equals('/api/session/ses-1/model', calls[5].request.path)
    assert.same(
      { model = { providerID = 'provider', id = 'model', variant = 'high' } },
      vim.json.decode(calls[5].request.body)
    )
    assert.equals('/api/session/ses-1/prompt', calls[6].request.path)
    assert.same({
      text = 'hello @main.lua',
      files = {
        {
          uri = 'data:text/plain;base64,c2VsZWN0ZWQ=',
          name = 'editor-context:selection:main.lua:1-2',
        },
        {
          uri = 'file:///server/project/main.lua',
          name = 'main.lua',
          mention = { start = 6, ['end'] = 15, text = '@main.lua' },
        },
      },
    }, vim.json.decode(calls[6].request.body))
    assert.equals('/api/session/ses-1/interrupt', calls[7].request.path)
  end)

  it('uses the fixed 2.0.1 active-session and inbox recovery contracts', function()
    local contract = vim.json.decode(fixture('observation-operations-2.0.1.json'))
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request
      if request.path == contract.list_active_sessions.request.path then
        return Promise.new():resolve({ status = 200, body = vim.json.encode(contract.list_active_sessions.response) })
      end
      if request.path == contract.list_inbox.request.path then
        return Promise.new():resolve({ status = 200, body = vim.json.encode(contract.list_inbox.response) })
      end
      error('unexpected request: ' .. request.path)
    end
    local function to_host(path)
      return path:gsub('^/server', '/host')
    end

    local active = operations.list_active_sessions(ready_connection()):wait()
    local inbox = operations.list_inbox(ready_connection(), 'ses-target', to_host):wait()

    assert.same({ ['ses-running'] = { type = 'running' } }, active)
    assert.equals('msg-user', inbox[1].id)
    assert.equals('/host/project', inbox[2].payload.location.directory)
    assert.same(contract.list_active_sessions.request, calls[1])
    assert.same(contract.list_inbox.request, calls[2])

    transport.request = function()
      return Promise.new():resolve({ status = 200, body = '{"data":{"ses-running":{"type":"idle"}}}' })
    end
    local ok, err = pcall(function()
      operations.list_active_sessions(ready_connection()):wait()
    end)
    assert.is_false(ok)
    assert.matches('invalid response', tostring(err))
  end)

  it('uses the fixed 2.0.1 session command contract and session settings', function()
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request
      return Promise.new():resolve({ status = 204, body = '' })
    end

    operations
      .send_command(ready_connection(), 'ses-1', nil, {
        command = 'review',
        arguments = 'staged changes',
        agent = 'build',
        model = 'provider/model',
        variant = 'high',
      })
      :wait()

    assert.same({ agent = 'build' }, vim.json.decode(calls[1].body))
    assert.same({ model = { providerID = 'provider', id = 'model', variant = 'high' } }, vim.json.decode(calls[2].body))
    assert.equals('/api/session/ses-1/command', calls[3].path)
    assert.same({ command = 'review', text = 'staged changes' }, vim.json.decode(calls[3].body))
  end)

  it('applies shared submission settings before the native V2 prompt', function()
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request
      if request.path:match('/prompt$') then
        return Promise.new():resolve({ status = 200, body = '{"data":{"id":"input-1"}}' })
      end
      return Promise.new():resolve({ status = 204, body = '' })
    end
    local input = {
      text = 'hello',
      context = {},
      files = {},
      agents = {},
      model = { providerID = 'provider', modelID = 'model' },
      agent = 'build',
      variant = 'high',
    }
    local original = vim.deepcopy(input)

    local admission = operations.submit(ready_connection(), 'ses-1', input):wait()

    assert.equals('input-1', admission.id)
    assert.equals(3, #calls)
    assert.equals('/api/session/ses-1/agent', calls[1].path)
    assert.same({ agent = 'build' }, vim.json.decode(calls[1].body))
    assert.equals('/api/session/ses-1/model', calls[2].path)
    assert.same({ model = { providerID = 'provider', id = 'model', variant = 'high' } }, vim.json.decode(calls[2].body))
    assert.equals('/api/session/ses-1/prompt', calls[3].path)
    assert.same({ text = 'hello' }, vim.json.decode(calls[3].body))
    assert.same(original, input)
  end)

  it('does not submit a prompt when a session setting fails', function()
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request.path
      return Promise.new():resolve({ status = 500, body = '{}' })
    end

    local ok = pcall(function()
      operations.submit(ready_connection(), 'ses-1', {
        text = 'hello',
        context = {},
        files = {},
        agents = {},
        model = { providerID = 'provider', modelID = 'model' },
      }):wait()
    end)

    assert.is_false(ok)
    assert.same({ '/api/session/ses-1/model' }, calls)
  end)

  it('rejects unsupported or invalid submission settings before business HTTP', function()
    local calls = 0
    transport.request = function()
      calls = calls + 1
      return Promise.new():resolve({ status = 200, body = '{}' })
    end
    local connection = ready_connection()

    local ok_system, system_error = pcall(function()
      operations
        .submit(connection, 'ses-1', {
          text = 'x',
          context = {},
          files = {},
          agents = {},
          system = 'custom',
        })
        :wait()
    end)
    local ok_tools, tools_error = pcall(function()
      operations
        .submit(connection, 'ses-1', {
          text = 'x',
          context = {},
          files = {},
          agents = {},
          tools = { bash = false },
        })
        :wait()
    end)
    local ok_model, model_error = pcall(function()
      operations
        .submit(connection, 'ses-1', {
          text = 'x',
          context = {},
          files = {},
          agents = {},
          model = { providerID = 'provider' },
        })
        :wait()
    end)
    assert.is_false(ok_system)
    assert.matches('system prompt', tostring(system_error))
    assert.is_false(ok_tools)
    assert.matches('tool selection', tostring(tools_error))
    assert.is_false(ok_model)
    assert.matches('model providerID and modelID', tostring(model_error))
    assert.equals(0, calls)
    assert.is_nil(operations.list_children)
  end)

  it('uses explicit location and Connection while cwd and responses interleave', function()
    local pending = {}
    transport.request = function(connection, request)
      local promise = Promise.new()
      pending[#pending + 1] = { connection = connection, request = request, promise = promise }
      return promise
    end
    state.context.set_current_cwd('/cwd-before')
    local first_connection = ready_connection('http://first.test')
    local first = operations.list_sessions(first_connection, { directory = '/remote/one' })
    state.context.set_current_cwd('/cwd-after')
    local second_connection = ready_connection('http://second.test')
    local second = operations.list_sessions(second_connection, { directory = '/remote/two' })

    assert.equals(first_connection, pending[1].connection)
    assert.equals(second_connection, pending[2].connection)
    assert.equals('directory=%2Fremote%2Fone', pending[1].request.query)
    assert.equals('directory=%2Fremote%2Ftwo', pending[2].request.query)
    pending[2].promise:resolve({ status = 200, body = '{"data":[{"id":"second"}]}' })
    pending[1].promise:resolve({ status = 200, body = '{"data":[{"id":"first"}]}' })
    assert.equals('first', first:wait().data[1].id)
    assert.equals('second', second:wait().data[1].id)
  end)

  it('fails on HTTP errors, invalid bodies, and wrong endpoint envelopes', function()
    local responses = {
      { status = 401, body = '{"error":"auth"}' },
      { status = 404, body = '{"error":"missing"}' },
      { status = 503, body = '{"error":"down"}' },
      { status = 200, body = '<html>' },
      { status = 200, body = '{"items":[]}' },
    }
    local calls = 0
    transport.request = function()
      calls = calls + 1
      return Promise.new():resolve(responses[calls])
    end

    for index, response in ipairs(responses) do
      local ok, err = pcall(function()
        operations.list_sessions(ready_connection(), { directory = '/remote' }):wait()
      end)
      assert.is_false(ok)
      if response.status ~= 200 then
        assert.matches('HTTP ' .. response.status, tostring(err))
      elseif index == 4 then
        assert.matches('invalid JSON', tostring(err))
      else
        assert.matches('page envelope', tostring(err))
      end
    end
  end)

  it('uses endpoint-native permission and question requests and exact 204 responses', function()
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request
      if request.method == 'GET' then
        return Promise.new():resolve({ status = 200, body = '{"data":[]}' })
      end
      return Promise.new():resolve({ status = 204, body = '' })
    end
    local connection = ready_connection()
    local location = { directory = '/remote/project' }

    assert.same({}, operations.list_permissions(connection, location):wait())
    assert.same({}, operations.list_questions(connection, location):wait())
    assert.is_true(operations.reply_permission(connection, 'ses-1', 'per-1', { reply = 'once' }):wait())
    assert.is_true(operations.reply_question(connection, 'ses-1', 'frm-1', { choice = 'a' }):wait())
    assert.is_true(operations.cancel_question(connection, 'ses-1', 'frm-1'):wait())

    assert.equals('/api/permission/request', calls[1].path)
    assert.equals('location.directory=%2Fremote%2Fproject', calls[1].query)
    assert.equals('/api/form', calls[2].path)
    assert.equals('/api/session/ses-1/permission/per-1/reply', calls[3].path)
    assert.equals('/api/session/ses-1/form/frm-1/reply', calls[4].path)
    assert.same({ answer = { choice = 'a' } }, vim.json.decode(calls[4].body))
    assert.equals('/api/session/ses-1/form/frm-1', calls[5].path)
    assert.is_nil(calls[5].body)
  end)

  it('uses the remaining proven project, catalog, filesystem, VCS, and MCP contracts', function()
    local calls = {}
    local empty = {
      ['/api/session/ses-1'] = true,
      ['/api/session/ses-1/rename'] = true,
      ['/api/experimental/mcp/test/connect'] = true,
      ['/api/experimental/mcp/test/disconnect'] = true,
    }
    local bodies = {
      ['/api/agent'] = '{"data":[{"name":"build"}]}',
      ['/api/model'] = '{"data":[{"providerID":"provider","id":"model"}]}',
      ['/api/model/default'] = '{"data":{"providerID":"provider","id":"model"}}',
      ['/api/command'] = '{"data":[{"name":"test"}]}',
      ['/api/skill'] = '{"data":[{"name":"test"}]}',
      ['/api/mcp'] = '{"data":{"test":{"status":"connected"}}}',
      ['/api/fs/find'] = '{"data":[{"path":"/server/project/main.lua"}]}',
      ['/api/vcs/status'] = '{"data":[{"file":"/server/project/main.lua","additions":1,"deletions":0}]}',
    }
    transport.request = function(_, request)
      calls[#calls + 1] = request
      if empty[request.path] then
        return Promise.new():resolve({ status = 204, body = '' })
      end
      return Promise.new():resolve({ status = 200, body = assert(bodies[request.path]) })
    end
    local connection = ready_connection()
    local location = { directory = '/host/project' }
    local function to_server(path)
      assert.is_nil(path:match('^/server'), 'path mapping must run once')
      return path:gsub('^/host', '/server')
    end
    local function to_host(path)
      return path:gsub('^/server', '/host')
    end

    assert.is_true(operations.delete_session(connection, 'ses-1'):wait())
    assert.is_true(operations.rename_session(connection, 'ses-1', nil, 'Renamed'):wait())
    local agents = operations.list_agents(connection, location, to_server, to_host):wait()
    local models = operations.list_models(connection, location, to_server, to_host):wait()
    local default_model = operations.get_default_model(connection, location, to_server, to_host):wait()
    local commands = operations.list_commands(connection, location, to_server, to_host):wait()
    local skills = operations.list_skills(connection, location, to_server, to_host):wait()
    local mcp = operations.list_mcp_servers(connection, location, to_server, to_host):wait()
    local found = operations.find_files(connection, 'main', location, to_server, to_host):wait()
    local status = operations.get_file_status(connection, location, to_server, to_host):wait()
    assert.is_true(operations.connect_mcp(connection, 'test', location, to_server):wait())
    assert.is_true(operations.disconnect_mcp(connection, 'test', location, to_server):wait())

    assert.equals('build', agents[1].name)
    assert.equals('model', models[1].id)
    assert.equals('model', default_model.id)
    assert.equals('test', commands[1].name)
    assert.equals('test', skills[1].name)
    assert.equals('connected', mcp.test.status)
    assert.equals('/host/project/main.lua', found[1])
    assert.equals('/host/project/main.lua', status[1].path)
    assert.equals(1, status[1].added)
    assert.equals(0, status[1].removed)

    assert.equals('DELETE', calls[1].method)
    assert.is_nil(calls[1].query)
    assert.same({ title = 'Renamed' }, vim.json.decode(calls[2].body))
    assert.equals('location.directory=%2Fserver%2Fproject&query=main&type=file', calls[9].query)
    assert.equals('location.directory=%2Fserver%2Fproject', calls[11].query)
    assert.equals('location.directory=%2Fserver%2Fproject', calls[12].query)
  end)

  it('maps the fixed 2.0.1 session lifecycle contracts and collects every list page', function()
    local calls = {}
    transport.request = function(_, request)
      calls[#calls + 1] = request
      if request.path == '/api/session' then
        if request.query:match('cursor=c2') then
          return Promise.new():resolve({
            status = 200,
            body = '{"data":[{"id":"s1"}],"cursor":{"previous":"c1","next":null}}',
          })
        end
        return Promise.new():resolve({
          status = 200,
          body = '{"data":[{"id":"s2"}],"cursor":{"next":"c2"}}',
        })
      end
      if request.path:match('/fork$') then
        return Promise.new():resolve({ status = 200, body = '{"data":{"id":"forked"}}' })
      end
      if request.path:match('/compact$') then
        return Promise.new():resolve({ status = 200, body = '{"data":{"id":"compact-admission"}}' })
      end
      if request.path:match('/revert/stage$') then
        return Promise.new():resolve({ status = 200, body = '{"data":{"messageID":"msg-1"}}' })
      end
      if request.path:match('/revert$') then
        return Promise.new():resolve({ status = 204, body = '' })
      end
      error('unexpected request: ' .. request.path)
    end
    local connection = ready_connection()
    local location = { directory = '/host/project' }
    local function to_server(path)
      return path:gsub('^/host', '/server')
    end

    local sessions = operations.list_sessions_project(connection, location, to_server):wait()
    local forked = operations.fork_session(connection, 'ses-1', location, { messageID = 'msg-1' }):wait()
    local compact = operations.summarize_session(connection, 'ses-1'):wait()
    local revert = operations.revert_message(connection, 'ses-1', location, { messageID = 'msg-1' }):wait()
    assert.is_true(operations.unrevert_messages(connection, 'ses-1'):wait())

    assert.same({ { id = 's2' }, { id = 's1' } }, sessions)
    assert.equals('forked', forked.id)
    assert.equals('compact-admission', compact.id)
    assert.equals('msg-1', revert.messageID)
    assert.equals('directory=%2Fserver%2Fproject&limit=100', calls[1].query)
    assert.equals('cursor=c2&directory=%2Fserver%2Fproject&limit=100', calls[2].query)
    assert.same({ boundary = { type = 'before', messageID = 'msg-1' } }, vim.json.decode(calls[3].body))
    assert.same({ delivery = 'steer' }, vim.json.decode(calls[4].body))
    assert.same({ files = true, messageID = 'msg-1' }, vim.json.decode(calls[5].body))
    assert.is_nil(calls[6].body)

    local init_ok, init_error = pcall(operations.init_session)
    local share_ok, share_error = pcall(operations.share_session)
    assert.is_false(init_ok)
    assert.matches('does not provide session initialization', tostring(init_error))
    assert.is_false(share_ok)
    assert.matches('does not provide session sharing', tostring(share_error))
  end)

  it('rejects a repeated V2 session-list cursor instead of looping', function()
    transport.request = function()
      return Promise.new():resolve({ status = 200, body = '{"data":[],"cursor":{"next":"same"}}' })
    end
    local ok, err = pcall(function()
      operations.list_sessions_global(ready_connection()):wait()
    end)
    assert.is_false(ok)
    assert.matches('invalid next cursor', tostring(err))
  end)

  it('interprets V2 model, agent, and command resources inside the V2 protocol', function()
    local bodies = {
      ['/api/provider'] = '{"location":{"directory":"/workspace"},"data":[{"id":"known","name":"Known"}]}',
      ['/api/model'] = '{"data":[{"providerID":"known","id":"m1"},{"providerID":"extra","id":"m2"}]}',
      ['/api/model/default'] = '{"data":{"providerID":"known","id":"m1"}}',
      ['/api/agent'] = '{"data":[{"id":"primary","mode":"primary"},{"id":"shared","mode":"all"},{"id":"helper","mode":"subagent"},{"id":"hidden","mode":"all","hidden":true}]}',
      ['/api/command'] = '{"data":[{"name":"review","template":"review $ARGUMENTS"}]}',
    }
    transport.request = function(_, request)
      return Promise.new():resolve({ status = 200, body = assert(bodies[request.path]) })
    end
    local connection = ready_connection()
    local location = { directory = '/workspace' }

    local catalog = operations.get_model_catalog(connection, location):wait()
    assert.equals('m1', catalog.default.known)
    assert.equals('m1', catalog.providers[1].models.m1.id)
    assert.equals('extra', catalog.providers[2].id)
    assert.equals('m2', catalog.providers[2].models.m2.id)
    assert.same({ 'primary', 'shared' }, operations.list_primary_agents(connection, location):wait())
    assert.same({ 'helper', 'shared' }, operations.list_subagents(connection, location):wait())
    assert.equals('review $ARGUMENTS', operations.get_user_commands(connection, location):wait().review.template)
  end)

  it('builds the V2 event stream without parsing the bytes', function()
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

    captured.on_chunk('data: {"type":"server.connected"}\n\n')
    assert.equals(connection, captured.connection)
    assert.same({ method = 'GET', path = '/api/event' }, captured.request)
    assert.same({ 'data: {"type":"server.connected"}\n\n' }, chunks)
  end)
end)
