local util = require('opencode.util')
local Promise = require('opencode.promise')
local http = require('opencode.protocols.http')
local transport = require('opencode.transport')

local M = {}

local function location_directory(location, path_map)
  return http.location_directory('V2', location, path_map)
end

local json_request = http.json_request
local map_paths = http.map_paths
local require_table = http.require_table

local function empty_request(connection, operation, method, path, body, query)
  return transport
    .request(connection, {
      method = method,
      path = path,
      query = query and http.query_string(query) or nil,
      body = body ~= nil and vim.json.encode(body) or nil,
    })
    :and_then(function(response)
      if response.status < 200 or response.status >= 300 then
        error(string.format('%s HTTP %d: %s', operation, response.status, response.body), 0)
      end
      if response.status ~= 204 or response.body ~= '' then
        error(operation .. ' returned an invalid empty response', 0)
      end
      return true
    end)
end

local function unwrap_data(operation, value, reverse_path_map)
  if type(value) ~= 'table' or value.data == nil then
    error(operation .. ' returned an invalid data envelope', 0)
  end
  return map_paths(value.data, reverse_path_map)
end

local function unwrap_page(operation, value, reverse_path_map)
  if type(value) ~= 'table' or type(value.data) ~= 'table' then
    error(operation .. ' returned an invalid page envelope', 0)
  end
  if value.cursor ~= nil and type(value.cursor) ~= 'table' then
    error(operation .. ' returned an invalid cursor', 0)
  end
  local cursor = {}
  for _, direction in ipairs({ 'previous', 'next' }) do
    local item = value.cursor and value.cursor[direction] or nil
    if item ~= nil and item ~= vim.NIL then
      if type(item) ~= 'string' or item == '' then
        error(operation .. ' returned an invalid cursor', 0)
      end
      cursor[direction] = item
    end
  end
  return {
    data = map_paths(value.data, reverse_path_map),
    cursor = cursor,
  }
end

function M.get_current_project(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 get_current_project', 'GET', '/api/project/current', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    return map_paths(require_table('V2 get_current_project', value), reverse_path_map)
  end)
end

function M.get_config(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 get_config', 'GET', '/api/config', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    return map_paths(require_table('V2 get_config', value), reverse_path_map)
  end)
end

function M.list_providers(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 list_providers', 'GET', '/api/provider', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    if type(value) ~= 'table' or type(value.location) ~= 'table' or type(value.data) ~= 'table' then
      error('V2 list_providers returned an invalid location/data envelope', 0)
    end
    return {
      location = value.location,
      data = map_paths(value.data, reverse_path_map),
    }
  end)
end

function M.list_sessions(connection, location, cursor, limit, path_map, reverse_path_map)
  local directory = location and location_directory(location, path_map) or nil
  return json_request(connection, 'V2 list_sessions', 'GET', '/api/session', {
    directory = directory,
    cursor = cursor,
    limit = limit,
  }):and_then(function(value)
    return unwrap_page('V2 list_sessions', value, reverse_path_map)
  end)
end

local function collect_sessions(connection, location, path_map, reverse_path_map)
  return Promise.async(function()
    local sessions = {}
    local cursor
    local seen = {}
    repeat
      local page = M.list_sessions(connection, location, cursor, 100, path_map, reverse_path_map):await()
      vim.list_extend(sessions, page.data)
      cursor = page.cursor.next
      if cursor ~= nil then
        if type(cursor) ~= 'string' or cursor == '' or seen[cursor] then
          error('V2 list_sessions returned an invalid next cursor', 0)
        end
        seen[cursor] = true
      end
    until cursor == nil
    return sessions
  end)()
end

function M.list_sessions_project(connection, location, path_map, reverse_path_map)
  return collect_sessions(connection, location, path_map, reverse_path_map)
end

function M.list_sessions_global(connection, reverse_path_map)
  return collect_sessions(connection, nil, nil, reverse_path_map)
end

function M.list_active_sessions(connection)
  return json_request(connection, 'V2 list_active_sessions', 'GET', '/api/session/active'):and_then(function(value)
    local active = require_table('V2 list_active_sessions', unwrap_data('V2 list_active_sessions', value))
    for session_id, state in pairs(active) do
      if type(session_id) ~= 'string' or type(state) ~= 'table' or state.type ~= 'running' then
        error('V2 list_active_sessions returned an invalid response', 0)
      end
    end
    return active
  end)
end

function M.list_inbox(connection, session_id, reverse_path_map)
  return json_request(connection, 'V2 list_inbox', 'GET', '/api/session/' .. session_id .. '/inbox'):and_then(
    function(value)
      local inbox = require_table('V2 list_inbox', unwrap_data('V2 list_inbox', value, reverse_path_map))
      for _, item in ipairs(inbox) do
        if
          type(item) ~= 'table'
          or type(item.id) ~= 'string'
          or type(item.sessionID) ~= 'string'
          or type(item.type) ~= 'string'
        then
          error('V2 list_inbox returned an invalid response', 0)
        end
      end
      return inbox
    end
  )
end

function M.create_session(connection, location, input, path_map, reverse_path_map)
  local body = map_paths(type(input) == 'table' and vim.deepcopy(input) or {}, path_map)
  body.location = { directory = location_directory(location, path_map) }
  return json_request(connection, 'V2 create_session', 'POST', '/api/session', nil, body):and_then(function(value)
    local session = unwrap_data('V2 create_session', value, reverse_path_map)
    return require_table('V2 create_session', session)
  end)
end

function M.get_session(connection, session_id, _location, _path_map, reverse_path_map)
  return json_request(connection, 'V2 get_session', 'GET', '/api/session/' .. session_id):and_then(function(value)
    local session = unwrap_data('V2 get_session', value, reverse_path_map)
    return require_table('V2 get_session', session)
  end)
end

function M.delete_session(connection, session_id)
  return empty_request(connection, 'V2 delete_session', 'DELETE', '/api/session/' .. session_id)
end

function M.rename_session(connection, session_id, _location, title)
  if type(title) ~= 'string' then
    error('V2 rename_session requires a title')
  end
  return empty_request(connection, 'V2 rename_session', 'POST', '/api/session/' .. session_id .. '/rename', {
    title = title,
  })
end

function M.init_session()
  error('V2 does not provide session initialization')
end

function M.share_session()
  error('V2 2.0.1 does not provide session sharing')
end

function M.unshare_session()
  error('V2 2.0.1 does not provide session sharing')
end

function M.summarize_session(connection, session_id)
  return json_request(connection, 'V2 summarize_session', 'POST', '/api/session/' .. session_id .. '/compact', nil, {
    delivery = 'steer',
  }):and_then(function(value)
    local admission = unwrap_data('V2 summarize_session', value)
    if type(admission) ~= 'table' or type(admission.id) ~= 'string' then
      error('V2 summarize_session returned an invalid admission', 0)
    end
    return admission
  end)
end

function M.fork_session(connection, session_id, _location, input, _path_map, reverse_path_map)
  input = type(input) == 'table' and input or {}
  local boundary
  if input.messageID == nil then
    boundary = { type = 'through' }
  elseif type(input.messageID) == 'string' and input.messageID ~= '' then
    boundary = { type = 'before', messageID = input.messageID }
  else
    error('V2 fork_session requires a valid messageID')
  end
  return json_request(connection, 'V2 fork_session', 'POST', '/api/session/' .. session_id .. '/fork', nil, {
    boundary = boundary,
  }):and_then(function(value)
    return require_table('V2 fork_session', unwrap_data('V2 fork_session', value, reverse_path_map))
  end)
end

function M.revert_message(connection, session_id, _location, input, _path_map, reverse_path_map)
  if type(input) ~= 'table' or type(input.messageID) ~= 'string' or input.messageID == '' then
    error('V2 revert_message requires a messageID')
  end
  return json_request(connection, 'V2 revert_message', 'POST', '/api/session/' .. session_id .. '/revert/stage', nil, {
    messageID = input.messageID,
    files = true,
  }):and_then(function(value)
    return require_table('V2 revert_message', unwrap_data('V2 revert_message', value, reverse_path_map))
  end)
end

function M.unrevert_messages(connection, session_id)
  return empty_request(connection, 'V2 unrevert_messages', 'POST', '/api/session/' .. session_id .. '/revert/clear')
end

function M.list_messages(connection, session_id, cursor, limit, reverse_path_map)
  return json_request(connection, 'V2 list_messages', 'GET', '/api/session/' .. session_id .. '/message', {
    cursor = cursor,
    limit = limit,
  }):and_then(function(value)
    return unwrap_page('V2 list_messages', value, reverse_path_map)
  end)
end

function M.set_session_agent(connection, session_id, agent)
  if type(agent) ~= 'string' or agent == '' then
    error('V2 session agent must be a non-empty string')
  end
  return empty_request(connection, 'V2 set_session_agent', 'POST', '/api/session/' .. session_id .. '/agent', {
    agent = agent,
  })
end

function M.set_session_model(connection, session_id, model)
  if
    type(model) ~= 'table'
    or type(model.providerID) ~= 'string'
    or type(model.id) ~= 'string'
    or (model.variant ~= nil and type(model.variant) ~= 'string')
  then
    error('V2 session model requires providerID, id, and an optional variant')
  end
  return empty_request(connection, 'V2 set_session_model', 'POST', '/api/session/' .. session_id .. '/model', {
    model = model,
  })
end

function M.send_command(connection, session_id, _location, input)
  if type(input) ~= 'table' or type(input.command) ~= 'string' or input.command == '' then
    error('V2 send_command requires a command')
  end
  return Promise.async(function()
    if input.agent then
      M.set_session_agent(connection, session_id, input.agent):await()
    end
    if input.model then
      local provider_id, model_id = input.model:match('^(.-)/(.+)$')
      if not provider_id or not model_id then
        error('V2 send_command model must use provider/model format')
      end
      M.set_session_model(connection, session_id, {
        providerID = provider_id,
        id = model_id,
        variant = input.variant,
      }):await()
    end
    return empty_request(connection, 'V2 send_command', 'POST', '/api/session/' .. session_id .. '/command', {
      command = input.command,
      text = input.arguments or '',
      files = input.files,
      agents = input.agents,
      skills = input.skills,
    }):await()
  end)()
end

local function prompt_body(input, path_map)
  if
    type(input) ~= 'table'
    or type(input.text) ~= 'string'
    or type(input.context) ~= 'table'
    or type(input.files) ~= 'table'
    or type(input.agents) ~= 'table'
  then
    error('V2 submit requires text, context, files, and agents')
  end
  if input.system ~= nil then
    error('V2 submit does not support a per-message system prompt')
  end
  if type(input.tools) == 'table' and next(input.tools) ~= nil then
    error('V2 submit does not support per-message tool selection')
  end
  for _, setting in ipairs({ 'model', 'agent', 'variant' }) do
    if input[setting] ~= nil then
      error('V2 submit does not support per-message ' .. setting)
    end
  end

  local context_text = {}
  for _, item in ipairs(input.context) do
    if type(item) ~= 'table' or type(item.text) ~= 'string' or type(item.source) ~= 'table' then
      error('V2 submit received invalid context')
    end
    local source = item.source
    if not vim.tbl_contains({ 'selection', 'diagnostics', 'cursor', 'buffer', 'git_diff' }, source.kind) then
      error('V2 submit received invalid context kind')
    end
    local label = '[context kind=' .. source.kind
    if source.file_name ~= nil then
      label = label .. ' file=' .. tostring(source.file_name)
    end
    if source.range ~= nil then
      label = label .. ' range=' .. tostring(source.range)
    end
    context_text[#context_text + 1] = label .. ']\n' .. item.text
  end

  local prefix = #context_text > 0 and table.concat(context_text, '\n\n') .. '\n\n' or ''
  local text = prefix .. input.text
  local prefix_units = util.utf16_index_from_byte(prefix, #prefix)
  if not prefix_units then
    error('V2 submit received non-UTF-8 context text', 0)
  end
  local function mention(value)
    if value == nil then
      return nil
    end
    if
      type(value) ~= 'table'
      or type(value.start_byte) ~= 'number'
      or type(value.end_byte) ~= 'number'
      or value.start_byte % 1 ~= 0
      or value.end_byte % 1 ~= 0
      or value.start_byte < 0
      or value.end_byte < value.start_byte
      or value.end_byte > #input.text
    then
      error('V2 submit received invalid mention')
    end
    local start = util.utf16_index_from_byte(input.text, value.start_byte)
    local finish = util.utf16_index_from_byte(input.text, value.end_byte)
    if
      not start
      or not finish
      or util.byte_index_from_utf16(input.text, start) ~= value.start_byte
      or util.byte_index_from_utf16(input.text, finish) ~= value.end_byte
    then
      error('V2 submit mention must use UTF-8 codepoint boundaries')
    end
    return {
      start = prefix_units + start,
      ['end'] = prefix_units + finish,
      text = input.text:sub(value.start_byte + 1, value.end_byte),
    }
  end

  local body = { text = text }
  if #input.files > 0 then
    body.files = {}
    for _, file in ipairs(input.files) do
      if
        type(file) ~= 'table'
        or type(file.media_type) ~= 'string'
        or (file.bytes == nil) == (file.server_uri == nil)
      then
        error('V2 submit received invalid file')
      end
      local uri
      if file.bytes ~= nil then
        if type(file.bytes) ~= 'string' then
          error('V2 submit received invalid file bytes')
        end
        uri = 'data:' .. file.media_type .. ';base64,' .. vim.base64.encode(file.bytes)
      elseif type(file.server_uri) == 'string' and file.server_uri:match('^file:///') then
        local path = file.server_uri:sub(8)
        uri = 'file://' .. (type(path_map) == 'function' and path_map(path) or path)
      else
        error('V2 submit server_uri must be an absolute file URI')
      end
      body.files[#body.files + 1] = { uri = uri, name = file.name, mention = mention(file.mention) }
    end
  end
  if #input.agents > 0 then
    body.agents = {}
    for _, agent in ipairs(input.agents) do
      if type(agent) ~= 'table' or type(agent.name) ~= 'string' or agent.name == '' then
        error('V2 submit received invalid agent attachment')
      end
      body.agents[#body.agents + 1] = { name = agent.name, mention = mention(agent.mention) }
    end
  end
  return body
end

function M.submit(connection, session_id, input, path_map, reverse_path_map)
  local body = prompt_body(input, path_map)
  return json_request(connection, 'V2 submit', 'POST', '/api/session/' .. session_id .. '/prompt', nil, body, path_map):and_then(
    function(value)
      local admission = unwrap_data('V2 submit', value, reverse_path_map)
      if type(admission) ~= 'table' or type(admission.id) ~= 'string' then
        error('V2 submit returned an invalid admission', 0)
      end
      return admission
    end
  )
end

function M.interrupt(connection, session_id)
  return json_request(connection, 'V2 interrupt', 'POST', '/api/session/' .. session_id .. '/interrupt'):and_then(
    function(value)
      if type(value) ~= 'table' or type(value.interrupted) ~= 'boolean' then
        error('V2 interrupt returned an invalid response', 0)
      end
      return value.interrupted
    end
  )
end

function M.list_permissions(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 list_permissions', 'GET', '/api/permission/request', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    return unwrap_data('V2 list_permissions', value, reverse_path_map)
  end)
end

function M.reply_permission(connection, session_id, request_id, answer)
  return empty_request(
    connection,
    'V2 reply_permission',
    'POST',
    '/api/session/' .. session_id .. '/permission/' .. request_id .. '/reply',
    answer
  )
end

function M.list_questions(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 list_questions', 'GET', '/api/form/request', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    return unwrap_data('V2 list_questions', value, reverse_path_map)
  end)
end

function M.reply_question(connection, session_id, request_id, answer)
  return empty_request(
    connection,
    'V2 reply_question',
    'POST',
    '/api/session/' .. session_id .. '/form/' .. request_id .. '/reply',
    { answer = answer }
  )
end

function M.cancel_question(connection, session_id, request_id)
  return empty_request(
    connection,
    'V2 cancel_question',
    'POST',
    '/api/session/' .. session_id .. '/form/' .. request_id .. '/cancel'
  )
end

local function data_list(connection, operation, path, location, path_map, reverse_path_map)
  return json_request(connection, operation, 'GET', path, {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    local data = unwrap_data(operation, value, reverse_path_map)
    return require_table(operation, data)
  end)
end

function M.list_agents(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 list_agents', '/api/agent', location, path_map, reverse_path_map)
end

function M.list_models(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 list_models', '/api/model', location, path_map, reverse_path_map)
end

function M.get_default_model(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 get_default_model', 'GET', '/api/model/default', {
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    return unwrap_data('V2 get_default_model', value, reverse_path_map)
  end)
end

M.get_model_catalog = Promise.async(function(connection, location, path_map, reverse_path_map)
  local provider_response = M.list_providers(connection, location, path_map, reverse_path_map):await()
  local models = M.list_models(connection, location, path_map, reverse_path_map):await()
  local default_model = M.get_default_model(connection, location, path_map, reverse_path_map):await()
  local providers = {}
  local providers_by_id = {}

  for _, provider in ipairs(provider_response.data) do
    if type(provider) ~= 'table' or type(provider.id) ~= 'string' then
      error('V2 model catalog received an invalid provider', 0)
    end
    local item = vim.tbl_extend('force', {}, provider, { models = {} })
    providers[#providers + 1] = item
    providers_by_id[item.id] = item
  end
  for _, model in ipairs(models) do
    local provider_id = model.providerID
    local model_id = model.modelID or model.id
    if type(provider_id) ~= 'string' or type(model_id) ~= 'string' then
      error('V2 model catalog received an invalid model', 0)
    end
    local provider = providers_by_id[provider_id]
    if not provider then
      provider = { id = provider_id, name = provider_id, models = {} }
      providers[#providers + 1] = provider
      providers_by_id[provider_id] = provider
    end
    provider.models[model_id] = vim.tbl_extend('force', {}, model, { id = model_id })
  end

  local defaults = {}
  if default_model and default_model.providerID and (default_model.modelID or default_model.id) then
    defaults[default_model.providerID] = default_model.modelID or default_model.id
  end
  return { providers = providers, default = defaults }
end)

local function select_agents(entries, accepts)
  local result = {}
  for _, agent in ipairs(entries) do
    local id = agent.id or agent.name
    if id and agent.disable ~= true and agent.hidden ~= true and accepts(agent.mode) then
      result[#result + 1] = id
    end
  end
  table.sort(result)
  return result
end

function M.list_primary_agents(connection, location, path_map, reverse_path_map)
  return M.list_agents(connection, location, path_map, reverse_path_map):and_then(function(entries)
    return select_agents(entries, function(mode)
      return mode == 'primary' or mode == 'all'
    end)
  end)
end

function M.list_subagents(connection, location, path_map, reverse_path_map)
  return M.list_agents(connection, location, path_map, reverse_path_map):and_then(function(entries)
    return select_agents(entries, function(mode)
      return mode == 'subagent' or mode == 'all'
    end)
  end)
end

function M.get_user_commands(connection, location, path_map, reverse_path_map)
  return M.list_commands(connection, location, path_map, reverse_path_map):and_then(function(commands)
    local result = {}
    for _, command in ipairs(commands) do
      if command.name then
        result[command.name] = command
      end
    end
    return result
  end)
end

function M.list_commands(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 list_commands', '/api/command', location, path_map, reverse_path_map)
end

function M.list_skills(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 list_skills', '/api/skill', location, path_map, reverse_path_map)
end

function M.list_mcp_servers(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 list_mcp_servers', '/api/mcp', location, path_map, reverse_path_map)
end

function M.find_files(connection, query, location, path_map, reverse_path_map)
  return json_request(connection, 'V2 find_files', 'GET', '/api/fs/find', {
    query = query,
    type = 'file',
    location = { directory = location_directory(location, path_map) },
  }):and_then(function(value)
    local data = require_table('V2 find_files', unwrap_data('V2 find_files', value, reverse_path_map))
    local paths = {}
    for index, entry in ipairs(data) do
      if type(entry) ~= 'table' or type(entry.path) ~= 'string' then
        error('V2 find_files returned an invalid response', 0)
      end
      paths[index] = entry.path
    end
    return paths
  end)
end

function M.get_file_status(connection, location, path_map, reverse_path_map)
  return data_list(connection, 'V2 get_file_status', '/api/vcs/status', location, path_map, reverse_path_map):and_then(
    function(data)
      local files = {}
      for index, entry in ipairs(data) do
        if type(entry) ~= 'table' or type(entry.file) ~= 'string' then
          error('V2 get_file_status returned an invalid response', 0)
        end
        files[index] = {
          path = entry.file,
          added = entry.additions,
          removed = entry.deletions,
          status = entry.status,
        }
      end
      return files
    end
  )
end

function M.connect_mcp(connection, name, location, path_map)
  if type(name) ~= 'string' or name == '' then
    error('V2 connect_mcp requires a server name')
  end
  return empty_request(connection, 'V2 connect_mcp', 'POST', '/api/mcp/' .. name .. '/connect', nil, {
    location = { directory = location_directory(location, path_map) },
  })
end

function M.disconnect_mcp(connection, name, location, path_map)
  if type(name) ~= 'string' or name == '' then
    error('V2 disconnect_mcp requires a server name')
  end
  return empty_request(connection, 'V2 disconnect_mcp', 'POST', '/api/mcp/' .. name .. '/disconnect', nil, {
    location = { directory = location_directory(location, path_map) },
  })
end

function M.subscribe_events(connection, on_chunk, on_disconnect)
  return transport.stream(connection, { method = 'GET', path = '/api/event' }, on_chunk, on_disconnect)
end

return M
