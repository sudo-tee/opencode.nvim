local http = require('opencode.protocols.http')
local transport = require('opencode.transport')

local M = {}

local function directory(location, path_map)
  return http.location_directory('V1', location, path_map)
end

local json_request = http.json_request
local empty_request = http.empty_request
local map_paths = http.map_paths
local require_table = http.require_table

local function table_result(operation, request, reverse_path_map)
  return request:and_then(function(value)
    return map_paths(require_table(operation, value), reverse_path_map)
  end)
end

local function boolean_result(operation, request)
  return request:and_then(function(value)
    if type(value) ~= 'boolean' then
      error(operation .. ' returned an invalid response', 0)
    end
    return value
  end)
end

function M.get_current_project(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 get_current_project', 'GET', '/project/current', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 get_current_project', value), reverse_path_map)
  end)
end

function M.get_config(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 get_config', 'GET', '/config', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 get_config', value), reverse_path_map)
  end)
end

function M.list_providers(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_providers', 'GET', '/config/providers', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 list_providers', value), reverse_path_map)
  end)
end

M.get_model_catalog = M.list_providers

local function configured_agents(config, accepts, defaults)
  local result = {}
  for name, options in pairs(config.agent or {}) do
    if options.disable ~= true and options.hidden ~= true and accepts(options.mode) then
      result[#result + 1] = name
    end
  end
  table.sort(result)
  for _, name in ipairs(defaults) do
    local options = config.agent and config.agent[name]
    if
      not vim.tbl_contains(result, name)
      and (options == nil or (options.disable ~= true and options.hidden ~= true))
    then
      table.insert(result, 1, name)
    end
  end
  return result
end

function M.list_primary_agents(connection, location, path_map, reverse_path_map)
  return M.get_config(connection, location, path_map, reverse_path_map):and_then(function(config)
    return configured_agents(config, function(mode)
      return mode == 'primary' or mode == 'all'
    end, { 'plan', 'build' })
  end)
end

function M.list_subagents(connection, location, path_map, reverse_path_map)
  return M.get_config(connection, location, path_map, reverse_path_map):and_then(function(config)
    return configured_agents(config, function(mode)
      return mode ~= 'primary' or mode == 'all'
    end, { 'general', 'explore' })
  end)
end

function M.get_user_commands(connection, location, path_map, reverse_path_map)
  return M.get_config(connection, location, path_map, reverse_path_map):and_then(function(config)
    return config.command
  end)
end

function M.list_sessions(connection, location, limit, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_sessions', 'GET', '/session', {
    directory = directory(location, path_map),
    limit = limit,
  }):and_then(function(value)
    return map_paths(require_table('V1 list_sessions', value), reverse_path_map)
  end)
end

function M.list_sessions_project(connection, location, path_map, reverse_path_map)
  return M.list_sessions(connection, location, nil, path_map, reverse_path_map)
end

function M.list_session_status(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 list_session_status',
    json_request(connection, 'V1 list_session_status', 'GET', '/session/status', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.list_sessions_global(connection, reverse_path_map)
  return table_result(
    'V1 list_sessions_global',
    json_request(connection, 'V1 list_sessions_global', 'GET', '/experimental/session'),
    reverse_path_map
  )
end

function M.create_session(connection, location, input, path_map, reverse_path_map)
  input = type(input) == 'table' and input or {}
  return json_request(connection, 'V1 create_session', 'POST', '/session', {
    directory = directory(location, path_map),
  }, input, path_map):and_then(function(value)
    return map_paths(require_table('V1 create_session', value), reverse_path_map)
  end)
end

function M.delete_session(connection, session_id, location, path_map)
  return boolean_result(
    'V1 delete_session',
    json_request(connection, 'V1 delete_session', 'DELETE', '/session/' .. session_id, {
      directory = directory(location, path_map),
    })
  )
end

function M.rename_session(connection, session_id, location, title, path_map, reverse_path_map)
  if type(title) ~= 'string' then
    error('V1 rename_session requires a title')
  end
  return table_result(
    'V1 rename_session',
    json_request(connection, 'V1 rename_session', 'PATCH', '/session/' .. session_id, {
      directory = directory(location, path_map),
    }, { title = title }, path_map),
    reverse_path_map
  ):and_then(function()
    return true
  end)
end

function M.get_session(connection, session_id, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 get_session', 'GET', '/session/' .. session_id, {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 get_session', value), reverse_path_map)
  end)
end

function M.list_children(connection, session_id, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_children', 'GET', '/session/' .. session_id .. '/children', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 list_children', value), reverse_path_map)
  end)
end

function M.init_session(connection, session_id, location, input, path_map)
  return boolean_result(
    'V1 init_session',
    json_request(connection, 'V1 init_session', 'POST', '/session/' .. session_id .. '/init', {
      directory = directory(location, path_map),
    }, input, path_map)
  )
end

function M.share_session(connection, session_id, location, path_map, reverse_path_map)
  return table_result(
    'V1 share_session',
    json_request(connection, 'V1 share_session', 'POST', '/session/' .. session_id .. '/share', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.unshare_session(connection, session_id, location, path_map, reverse_path_map)
  return table_result(
    'V1 unshare_session',
    json_request(connection, 'V1 unshare_session', 'DELETE', '/session/' .. session_id .. '/share', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.summarize_session(connection, session_id, location, input, path_map)
  return boolean_result(
    'V1 summarize_session',
    json_request(connection, 'V1 summarize_session', 'POST', '/session/' .. session_id .. '/summarize', {
      directory = directory(location, path_map),
    }, input, path_map)
  )
end

function M.fork_session(connection, session_id, location, input, path_map, reverse_path_map)
  return table_result(
    'V1 fork_session',
    json_request(connection, 'V1 fork_session', 'POST', '/session/' .. session_id .. '/fork', {
      directory = directory(location, path_map),
    }, input, path_map),
    reverse_path_map
  )
end

function M.list_messages(connection, session_id, location, limit, before, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_messages', 'GET', '/session/' .. session_id .. '/message', {
    directory = directory(location, path_map),
    limit = limit,
    before = before,
  }):and_then(function(value)
    return map_paths(require_table('V1 list_messages', value), reverse_path_map)
  end)
end

function M.submit(connection, session_id, location, input, path_map, reverse_path_map)
  return json_request(connection, 'V1 submit', 'POST', '/session/' .. session_id .. '/message', {
    directory = directory(location, path_map),
  }, input, path_map):and_then(function(value)
    if type(value) ~= 'table' or type(value.info) ~= 'table' or type(value.parts) ~= 'table' then
      error('V1 submit returned an invalid message response', 0)
    end
    return map_paths(value, reverse_path_map)
  end)
end

function M.submit_async(connection, session_id, location, input, path_map)
  return empty_request(
    connection,
    'V1 submit async',
    'POST',
    '/session/' .. session_id .. '/prompt_async',
    { directory = directory(location, path_map) },
    input,
    path_map
  )
end

function M.send_command(connection, session_id, location, input, path_map, reverse_path_map)
  return table_result(
    'V1 send_command',
    json_request(connection, 'V1 send_command', 'POST', '/session/' .. session_id .. '/command', {
      directory = directory(location, path_map),
    }, input, path_map),
    reverse_path_map
  )
end

function M.revert_message(connection, session_id, location, input, path_map, reverse_path_map)
  return table_result(
    'V1 revert_message',
    json_request(connection, 'V1 revert_message', 'POST', '/session/' .. session_id .. '/revert', {
      directory = directory(location, path_map),
    }, input, path_map),
    reverse_path_map
  )
end

function M.unrevert_messages(connection, session_id, location, path_map, reverse_path_map)
  return table_result(
    'V1 unrevert_messages',
    json_request(connection, 'V1 unrevert_messages', 'POST', '/session/' .. session_id .. '/unrevert', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.interrupt(connection, session_id, location, path_map)
  return json_request(connection, 'V1 interrupt', 'POST', '/session/' .. session_id .. '/abort', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    if type(value) ~= 'boolean' then
      error('V1 interrupt returned an invalid response', 0)
    end
    return value
  end)
end

function M.list_permissions(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_permissions', 'GET', '/permission', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 list_permissions', value), reverse_path_map)
  end)
end

function M.reply_permission(connection, request_id, location, answer, path_map)
  return json_request(connection, 'V1 reply_permission', 'POST', '/permission/' .. request_id .. '/reply', {
    directory = directory(location, path_map),
  }, answer, path_map):and_then(function(value)
    if type(value) ~= 'boolean' then
      error('V1 reply_permission returned an invalid response', 0)
    end
    return value
  end)
end

function M.list_questions(connection, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 list_questions', 'GET', '/question', {
    directory = directory(location, path_map),
  }):and_then(function(value)
    return map_paths(require_table('V1 list_questions', value), reverse_path_map)
  end)
end

function M.reply_question(connection, request_id, location, answers, path_map)
  return json_request(connection, 'V1 reply_question', 'POST', '/question/' .. request_id .. '/reply', {
    directory = directory(location, path_map),
  }, { answers = answers }, path_map):and_then(function(value)
    if type(value) ~= 'boolean' then
      error('V1 reply_question returned an invalid response', 0)
    end
    return value
  end)
end

function M.reject_question(connection, request_id, location, path_map)
  return boolean_result(
    'V1 reject_question',
    json_request(connection, 'V1 reject_question', 'POST', '/question/' .. request_id .. '/reject', {
      directory = directory(location, path_map),
    })
  )
end

function M.list_commands(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 list_commands',
    json_request(connection, 'V1 list_commands', 'GET', '/command', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.find_files(connection, query, location, path_map, reverse_path_map)
  return json_request(connection, 'V1 find_files', 'GET', '/find/file', {
    query = query,
    directory = directory(location, path_map),
  }):and_then(function(value)
    require_table('V1 find_files', value)
    if type(reverse_path_map) ~= 'function' then
      return value
    end
    local paths = {}
    for index, path in ipairs(value) do
      if type(path) ~= 'string' then
        error('V1 find_files returned an invalid response', 0)
      end
      paths[index] = reverse_path_map(path)
    end
    return paths
  end)
end

function M.get_file_status(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 get_file_status',
    json_request(connection, 'V1 get_file_status', 'GET', '/file/status', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.list_agents(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 list_agents',
    json_request(connection, 'V1 list_agents', 'GET', '/agent', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.list_skills(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 list_skills',
    json_request(connection, 'V1 list_skills', 'GET', '/skill', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.list_mcp_servers(connection, location, path_map, reverse_path_map)
  return table_result(
    'V1 list_mcp_servers',
    json_request(connection, 'V1 list_mcp_servers', 'GET', '/mcp', {
      directory = directory(location, path_map),
    }),
    reverse_path_map
  )
end

function M.connect_mcp(connection, name, location, path_map)
  return boolean_result(
    'V1 connect_mcp',
    json_request(connection, 'V1 connect_mcp', 'POST', '/mcp/' .. name .. '/connect', {
      directory = directory(location, path_map),
    })
  )
end

function M.disconnect_mcp(connection, name, location, path_map)
  return boolean_result(
    'V1 disconnect_mcp',
    json_request(connection, 'V1 disconnect_mcp', 'POST', '/mcp/' .. name .. '/disconnect', {
      directory = directory(location, path_map),
    })
  )
end

function M.subscribe_events(connection, on_chunk, on_disconnect)
  return transport.stream(connection, { method = 'GET', path = '/global/event' }, on_chunk, on_disconnect)
end

return M
