local server_job = require('pi.server_job')
local state = require('pi.state')
local config = require('pi.config')
local url_encode = require('pi.util').url_encode
local apply_path_map = require('pi.util').apply_path_map
local reverse_transform_paths_recursive = require('pi.util').reverse_transform_paths_recursive
local transform_paths_recursive = require('pi.util').transform_paths_recursive
local is_version_greater_or_equal = require('pi.util').is_version_greater_or_equal

--- @class PiApiClient
--- @field base_url string The base URL of the pi server
local PiApiClient = {}
PiApiClient.__index = PiApiClient

--- Create a new API client instance
--- @param base_url? string The base URL of the pi server
--- @return PiApiClient
function PiApiClient.new(base_url)
  return setmetatable({
    base_url = base_url and base_url:gsub('/$', ''), -- Remove trailing slash
  }, PiApiClient)
end

---Convert /global/event envelopes into the legacy event shape consumed by the
---rest of the plugin.
---@param event table|nil
---@return table|nil
local function normalize_global_event(event)
  if type(event) ~= 'table' then
    return nil
  end

  local payload = event.payload
  if type(payload) ~= 'table' then
    return nil
  end

  if payload.type == 'sync' then
    local sync_event = payload.syncEvent
    if type(sync_event) ~= 'table' then
      return nil
    end

    local event_type = sync_event.type
    if type(event_type) ~= 'string' then
      return nil
    end

    event_type = event_type:gsub('%.%d+$', '')

    return {
      id = sync_event.id or payload.id,
      type = event_type,
      properties = sync_event.data,
    }
  end

  if type(payload.type) ~= 'string' then
    return nil
  end

  return {
    id = payload.id,
    type = payload.type,
    properties = payload.properties,
  }
end

---Ensure that base_url is set. Even thought we're subscribed to
---state.pi_server, we still need this check because
---it's possible someone will try to make an api call in their event
---handler (e.g. event_manager or header)
---@return boolean
function PiApiClient:_ensure_base_url()
  -- NOTE: eventhough we're subscribed pi_server, we need this check for
  -- base_url because the notification about pi_server being set to
  -- non-nil my not have gotten to us in time
  if self.base_url then
    return true
  end

  if not state.pi_server then
    -- this is last resort - try to start the server and could be blocking
    state.jobs.set_server(server_job.ensure_server():wait() --[[@as PiServer]])
    -- shouldn't normally happen but prevents error in replay tester
    if not state.pi_server then
      return false
    end
  end

  if not state.pi_server.url then
    state.pi_server:get_spawn_promise():wait()
    if not state.pi_server.url then
      return false
    end
  end

  self.base_url = state.pi_server.url:gsub('/$', '')
  return true
end

--- Make a typed API call
--- @param endpoint string The API endpoint path
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil|boolean Request body
--- @param query table|nil Query parameters
--- @return Promise<any> promise
function PiApiClient:_call(endpoint, method, body, query)
  if not self:_ensure_base_url() then
    return require('pi.promise').new():reject('No server base url')
  end
  local url = self.base_url .. endpoint

  if query then
    if not query.directory then
      query.directory = state.current_cwd or vim.fn.getcwd()
    end

    query = transform_paths_recursive(query)

    local params = {}

    for k, v in pairs(query) do
      if v ~= nil then
        table.insert(params, url_encode(k) .. '=' .. url_encode(v))
      end
    end

    if #params > 0 then
      url = url .. '?' .. table.concat(params, '&')
    end
  end

  if body and type(body) == 'table' then
    body = transform_paths_recursive(body)
  end

  return server_job.call_api(url, method, body):and_then(function(result)
    return reverse_transform_paths_recursive(result)
  end)
end

-- Project endpoints

--- List all projects
--- @param directory string|nil Directory path
--- @return Promise<PiProject[]>
function PiApiClient:list_projects(directory)
  return self:_call('/project', 'GET', nil, { directory = directory })
end

--- Get the current project
--- @param directory string|nil Directory path
--- @return Promise<PiProject>
function PiApiClient:get_current_project(directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve({
      id = vim.fn.sha256(vim.fn.getcwd()),
      directory = vim.fn.getcwd(),
      name = vim.fn.fnamemodify(vim.fn.getcwd(), ':t'),
    })
  end
  return self:_call('/project/current', 'GET', nil, { directory = directory })
end

-- Config endpoints

--- Get config info
--- @param directory string|nil Directory path
--- @return Promise<PiConfig>
function PiApiClient:get_config(directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve({
      agent = {},
      command = {},
      mcp = {},
    })
  end
  return self:_call('/config', 'GET', nil, { directory = directory })
end

--- Update config
--- @param config PiConfig Config object to update
--- @param directory string|nil Directory path
--- @return Promise<PiConfig>
function PiApiClient:update_config(config, directory)
  return self:_call('/config', 'PATCH', config, { directory = directory })
end

--- List all providers
--- @param directory string|nil Directory path
--- @return Promise<PiProvidersResponse>
function PiApiClient:list_providers(directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():get_available_models():and_then(function(data)
      local providers = {}
      for _, model in ipairs(data.models or {}) do
        local provider = providers[model.provider]
        if not provider then
          provider = { id = model.provider, name = model.provider, models = {} }
          providers[model.provider] = provider
        end
        provider.models[model.id] = {
          id = model.id,
          name = model.name or model.id,
          providerID = model.provider,
        }
      end
      local list = {}
      for _, provider in pairs(providers) do
        table.insert(list, provider)
      end
      return { providers = list }
    end)
  end
  return self:_call('/config/providers', 'GET', nil, { directory = directory })
end

--- Get the current path
--- @param directory string|nil Directory path
--- @return Promise<PiPath>
function PiApiClient:get_path(directory)
  return self:_call('/path', 'GET', nil, { directory = directory })
end

-- Session endpoints

--- List all sessions
--- @param directory string|nil Directory path
--- @return Promise<Session[]>
function PiApiClient:list_sessions(directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve(require('pi.pi_sessions').list_workspace_sessions(directory or vim.fn.getcwd()))
  end
  return self:_call('/session', 'GET', nil, { directory = directory })
end

--- List the current status of all sessions in a workspace.
--- @param directory string|nil Directory path
--- @return Promise<{[string]: PiSessionStatusInfo}>
function PiApiClient:list_session_status(directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():get_state():and_then(function(pi_state)
      local id = pi_state.sessionFile or pi_state.sessionId or (state.active_session and state.active_session.id)
      if not id then
        return {}
      end
      return {
        [id] = {
          type = pi_state.isStreaming and 'busy' or 'idle',
          message = pi_state.isCompacting and 'Compacting session' or nil,
        },
      }
    end)
  end
  return self:_call('/session/status', 'GET', nil, { directory = directory })
end

--- List sessions across all projects (experimental global endpoint).
--- Bypasses _call's automatic directory injection so the server returns all
--- directories instead of being filtered to the current cwd.
--- @return Promise<GlobalSession[]>
function PiApiClient:list_sessions_global()
  if not self:_ensure_base_url() then
    return require('pi.promise').new():reject('No server base url')
  end
  return server_job.call_api(self.base_url .. '/experimental/session', 'GET')
end

--- Create a new session
--- @param session_data {parentID?: string, title?: string}|nil|boolean Session creation data
--- @param directory string|nil  Directory path
--- @return Promise<Session>
function PiApiClient:create_session(session_data, directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():new_session():and_then(function()
      return require('pi.rpc_client').get():get_state()
    end):and_then(function(pi_state)
      local id = pi_state.sessionId or pi_state.sessionFile or 'pi-session'
      return {
        id = id,
        title = pi_state.sessionName or 'Pi session',
        directory = vim.fn.getcwd(),
        time = { created = vim.uv.now(), updated = vim.uv.now() },
      }
    end)
  end
  return self:_call('/session', 'POST', session_data or false, { directory = directory })
end

--- Get session by ID
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:get_session(id, directory)
  if config.backend == 'pi' then
    local rpc = require('pi.rpc_client').get()
    return rpc:get_state():and_then(function(pi_state)
      local target = require('pi.pi_sessions').get_by_path(id)
      if target and pi_state.sessionFile ~= target.path then
        return rpc:switch_session(target.path):and_then(function(result)
          if result and result.cancelled then
            return target
          end
          return rpc:get_state():and_then(function(new_state)
            target.sessionID = new_state.sessionId or target.sessionID
            target.title = new_state.sessionName or target.title
            return target
          end)
        end)
      end

      if target then
        return target
      end

      return {
        id = pi_state.sessionFile or pi_state.sessionId or id or 'pi-session',
        title = pi_state.sessionName or 'Pi session',
        directory = vim.fn.getcwd(),
        path = pi_state.sessionFile,
        sessionFile = pi_state.sessionFile,
        sessionID = pi_state.sessionId,
        time = { created = vim.uv.now(), updated = vim.uv.now() },
      }
    end)
  end
  return self:_call('/session/' .. id, 'GET', nil, { directory = directory })
end

--- Delete a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:delete_session(id, directory)
  return self:_call('/session/' .. id, 'DELETE', nil, { directory = directory })
end

--- Update session properties
--- @param id string Session ID (required)
--- @param session_update {title?: string} Session update data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:update_session(id, session_update, directory)
  return self:_call('/session/' .. id, 'PATCH', session_update, { directory = directory })
end

--- Get a session's children
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session[]>
function PiApiClient:get_session_children(id, directory)
  return self:_call('/session/' .. id .. '/children', 'GET', nil, { directory = directory })
end

--- Initialize session (analyze app and create AGENTS.md)
--- @param id string Session ID (required)
--- @param init_data {messageID: string, providerID: string, modelID: string} Initialization data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:init_session(id, init_data, directory)
  return self:_call('/session/' .. id .. '/init', 'POST', init_data, { directory = directory })
end

--- Abort a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:abort_session(id, directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():abort()
  end
  return self:_call('/session/' .. id .. '/abort', 'POST', nil, { directory = directory })
end

--- Share a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:share_session(id, directory)
  return self:_call('/session/' .. id .. '/share', 'POST', nil, { directory = directory })
end

--- Unshare a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:unshare_session(id, directory)
  return self:_call('/session/' .. id .. '/share', 'DELETE', nil, { directory = directory })
end

--- Summarize a session
--- @param id string Session ID (required)
--- @param summary_data {providerID: string, modelID: string} Summary data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:summarize_session(id, summary_data, directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():compact()
  end
  return self:_call('/session/' .. id .. '/summarize', 'POST', summary_data, { directory = directory })
end

--- Fork an existing session at a specific message
--- @param id string Session ID (required)
--- @param fork_data {messageID?: string}|nil Fork data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:fork_session(id, fork_data, directory)
  if config.backend == 'pi' then
    local rpc = require('pi.rpc_client').get()
    if fork_data and fork_data.messageID then
      return rpc:fork(fork_data.messageID)
    end
    return rpc:clone()
  end
  return self:_call('/session/' .. id .. '/fork', 'POST', fork_data, { directory = directory })
end

-- Message endpoints

--- List messages for a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @param opts? { limit?: number } Optional query parameters
--- @return Promise<PiMessage[]>
function PiApiClient:list_messages(id, directory, opts)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():get_messages():and_then(function(data)
      return require('pi.event_adapter').messages_from_pi(data.messages or {})
    end)
  end
  local query = { directory = directory }
  if opts then
    for k, v in pairs(opts) do
      query[k] = v
    end
  end
  return self:_call('/session/' .. id .. '/message', 'GET', nil, query)
end

--- Create and send a new message to a session
--- @param id string Session ID (required)
--- @param message_data {messageID?: string, model?: {providerID: string, modelID: string}, agent?: string, variant?: string, system?: string, tools?: table<string, boolean>, parts: PiMessagePart[]} Message creation data
--- @param directory string|nil Directory path
--- @return Promise<{info: MessageInfo, parts: PiMessagePart[]}>
function PiApiClient:create_message(id, message_data, directory)
  if config.backend == 'pi' then
    local message = require('pi.prompt_adapter').parts_to_prompt(message_data.parts or {})
    return require('pi.rpc_client').get():prompt(message):and_then(function()
      return {
        info = { id = 'pi-user-accepted', role = 'user', sessionID = id, time = { created = vim.uv.now() } },
        parts = message_data.parts or {},
      }
    end)
  end
  return self:_call('/session/' .. id .. '/message', 'POST', message_data, { directory = directory })
end

--- Get a message from a session
--- @param id string Session ID (required)
--- @param messageID string Message ID (required)
--- @param directory string|nil Directory path
--- @return Promise<PiMessage>
function PiApiClient:get_message(id, messageID, directory)
  return self:_call('/session/' .. id .. '/message/' .. messageID, 'GET', nil, { directory = directory })
end

--- Send a command to a session
--- @param id string Session ID (required)
--- @param command_data {messageID?: string, agent?: string, model?: string, arguments: string, command: string} Command data
--- @param directory string|nil Directory path
--- @return Promise<PiMessage>
function PiApiClient:send_command(id, command_data, directory)
  if config.backend == 'pi' then
    local message = '/' .. tostring(command_data.command or '')
    if command_data.arguments and command_data.arguments ~= '' then
      message = message .. ' ' .. command_data.arguments
    end
    return require('pi.rpc_client').get():prompt(message)
  end
  return self:_call('/session/' .. id .. '/command', 'POST', command_data, { directory = directory })
end

--- Run a shell command
--- @param id string Session ID (required)
--- @param shell_data {agent?: string, command: string} Shell command data
--- @param directory string|nil Directory path
--- @return Promise<MessageInfo>
function PiApiClient:run_shell(id, shell_data, directory)
  return self:_call('/session/' .. id .. '/shell', 'POST', shell_data, { directory = directory })
end

--- Revert a message
--- @param id string Session ID (required)
--- @param revert_data {messageID: string, partID?: string} Revert data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:revert_message(id, revert_data, directory)
  return self:_call('/session/' .. id .. '/revert', 'POST', revert_data, { directory = directory })
end

--- Restore all reverted messages
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function PiApiClient:unrevert_messages(id, directory)
  return self:_call('/session/' .. id .. '/unrevert', 'POST', nil, { directory = directory })
end

--- List pending permissions
--- @param directory string|nil Directory path
--- @return Promise<PiPermission[]>
function PiApiClient:list_permissions(directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve({})
  end
  return self:_call('/permission', 'GET', nil, { directory = directory })
end

--- Respond to a permission request
--- @param id string Session ID (required)
--- @param permissionID string Permission ID (required)
--- @param response_data {response: "once"|"always"|"reject", message?: string} Response data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:respond_to_permission(id, permissionID, response_data, directory)
  return self:_call(
    '/session/' .. id .. '/permissions/' .. permissionID,
    'POST',
    response_data,
    { directory = directory }
  )
end

--- Reply to a permission (accept/reject)
--- @param requestID string Permission request ID (prefixed with "per")
--- @param response_data {reply: "once"|"always"|"reject", message?: string} Response data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:reply_to_permission(requestID, response_data, directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve(true)
  end
  return self:_call('/permission/' .. requestID .. '/reply', 'POST', response_data, { directory = directory })
end

--- List all commands
--- @param directory string|nil Directory path
--- @return Promise<PiCommand[]>
function PiApiClient:list_commands(directory)
  return self:_call('/command', 'GET', nil, { directory = directory })
end

--- Find text in files
--- @param pattern string Search pattern (required)
--- @param directory string|nil Directory path
--- @return Promise<table[]> Search results
function PiApiClient:find_text(pattern, directory)
  return self:_call('/find', 'GET', nil, {
    pattern = pattern,
    directory = directory,
  })
end

--- Find files
--- @param query string File search query (required)
--- @param directory string|nil Directory path
--- @return Promise<string[]> File paths
function PiApiClient:find_files(query, directory)
  return self:_call('/find/file', 'GET', nil, {
    query = query,
    directory = directory,
  })
end

--- Find workspace symbols
--- @param query string Symbol search query (required)
--- @param directory string|nil Directory path
--- @return Promise<table[]> Symbols
function PiApiClient:find_symbols(query, directory)
  return self:_call('/find/symbol', 'GET', nil, {
    query = query,
    directory = directory,
  })
end

-- File endpoints

--- List files and directories
--- @param path string File path (required)
--- @param directory string|nil Directory path
--- @return Promise<table[]>
function PiApiClient:list_files(path, directory)
  return self:_call('/file', 'GET', nil, {
    path = path,
    directory = directory,
  })
end

--- Read a file
--- @param path string File path (required)
--- @param directory string|nil Directory path
--- @return Promise<table>
function PiApiClient:read_file(path, directory)
  return self:_call('/file/content', 'GET', nil, {
    path = path,
    directory = directory,
  })
end

--- Get file status
--- @param directory string|nil Directory path
--- @return Promise<table[]>
function PiApiClient:get_file_status(directory)
  return self:_call('/file/status', 'GET', nil, { directory = directory })
end

-- Log endpoints

--- Write a log entry to the server logs
--- @param log_data {service: string, level: "debug"|"info"|"error"|"warn", message: string, extra?: table<string, any>} Log entry data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:write_log(log_data, directory)
  return self:_call('/log', 'POST', log_data, { directory = directory })
end

-- Agent endpoints

--- List all agents
--- @param directory string|nil Directory path
--- @return Promise<PiAgent[]>
function PiApiClient:list_agents(directory)
  return self:_call('/agent', 'GET', nil, { directory = directory })
end

-- Question endpoints

--- List pending questions
--- @param directory string|nil Directory path
--- @return Promise<PiQuestionRequest[]>
function PiApiClient:list_questions(directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve({})
  end
  return self:_call('/question', 'GET', nil, { directory = directory })
end

--- Reply to a question
--- @param requestID string Question request ID (required)
--- @param answers string[][] Array of answers (each answer is array of selected labels)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:reply_question(requestID, answers, directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve(true)
  end
  return self:_call('/question/' .. requestID .. '/reply', 'POST', { answers = answers }, { directory = directory })
end

--- Reject a question
--- @param requestID string Question request ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:reject_question(requestID, directory)
  if config.backend == 'pi' then
    return require('pi.promise').new():resolve(true)
  end
  return self:_call('/question/' .. requestID .. '/reject', 'POST', nil, { directory = directory })
end

--- Subscribe to events (streaming)
--- @param directory string|nil Directory path
--- @param on_event fun(event: table) Event callback
--- @return table The streaming job handle
function PiApiClient:subscribe_to_events(directory, on_event)
  -- Make sure we have a base URL before attempting to subscribe. If we
  -- cannot determine a base URL (server not running), return nil so
  -- callers can handle the absence of a subscription without an error.
  if not self:_ensure_base_url() then
    return nil
  end

  local version = assert(state.pi_cli_version):wait()
  if is_version_greater_or_equal(version, '1.14.42') then
    return self:_subscribe_to_global_events(directory, on_event)
  end

  local url = self.base_url .. '/event'
  if directory then
    local mapped_directory = apply_path_map(directory)
    url = url .. '?directory=' .. url_encode(mapped_directory)
  end

  return server_job.stream_api(url, 'GET', nil, function(chunk)
    chunk = chunk:gsub('^data:%s*', '')
    local ok, event = pcall(vim.json.decode, vim.trim(chunk))
    if ok and event then
      local transformed_event = reverse_transform_paths_recursive(event)
      on_event(transformed_event --[[@as table]])
    end
  end)
end

--- Subscribe to events (streaming)
--- @param directory string|nil Directory path
--- @param on_event fun(event: table) Event callback
--- @return table The streaming job handle
function PiApiClient:_subscribe_to_global_events(directory, on_event)
  -- Ensure base_url is available. If not, return nil instead of erroring.
  if not self:_ensure_base_url() then
    return nil
  end

  local version = assert(state.pi_cli_version):wait()
  if not is_version_greater_or_equal(version, '1.14.42') then
    error('subscribe_to_global_events should not be called directly')
  end

  local url = self.base_url .. '/global/event'
  if directory then
    local mapped_directory = apply_path_map(directory)
    url = url .. '?directory=' .. url_encode(mapped_directory)
  end

  return server_job.stream_api(url, 'GET', nil, function(chunk)
    chunk = chunk:gsub('^data:%s*', '')
    local ok, event = pcall(vim.json.decode, vim.trim(chunk))
    if ok and event then
      local normalized_event = normalize_global_event(event)
      if normalized_event then
        local transformed_event = reverse_transform_paths_recursive(normalized_event)
        on_event(transformed_event --[[@as table]])
      end
    end
  end)
end

-- Skill endpoints

--- List all skills
--- @param directory string|nil Directory path
--- @return Promise<PiSkill[]>
function PiApiClient:list_skills(directory)
  if config.backend == 'pi' then
    return require('pi.rpc_client').get():get_commands():and_then(function(data)
      local skills = {}
      for _, command in ipairs(data.commands or {}) do
        if command.source == 'skill' then
          table.insert(skills, {
            name = command.name:gsub('^skill:', ''),
            description = command.description,
            content = '/' .. command.name,
          })
        end
      end
      return skills
    end)
  end
  return self:_call('/skill', 'GET', nil, { directory = directory })
end

-- Tool endpoints

--- List all tool IDs (including built-in and dynamically registered)
--- @param directory string|nil Directory path
--- @return Promise<string[]>
function PiApiClient:list_tool_ids(directory)
  return self:_call('/experimental/tool/ids', 'GET', nil, { directory = directory })
end

--- List tools with JSON schema parameters for a provider/model
--- @param provider string Provider name (required)
--- @param model string Model name (required)
--- @param directory string|nil Directory path
--- @return Promise<PiToolList>
function PiApiClient:list_tools(provider, model, directory)
  return self:_call('/experimental/tool', 'GET', nil, {
    provider = provider,
    model = model,
    directory = directory,
  })
end

-- MCP endpoints

--- List all MCP servers
--- @param directory string|nil Directory path
--- @return Promise<table<string, table>>
function PiApiClient:list_mcp_servers(directory)
  return self:_call('/mcp', 'GET', nil, { directory = directory })
end

--- Connect an MCP server
--- @param name string MCP server name (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:connect_mcp(name, directory)
  if not name or name == '' then
    return require('pi.promise').new():reject('MCP server name is required')
  end
  return self:_call('/mcp/' .. name .. '/connect', 'POST', nil, { directory = directory })
end

--- Disconnect an MCP server
--- @param name string MCP server name (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function PiApiClient:disconnect_mcp(name, directory)
  if not name or name == '' then
    return require('pi.promise').new():reject('MCP server name is required')
  end
  return self:_call('/mcp/' .. name .. '/disconnect', 'POST', nil, { directory = directory })
end

--- Create a factory function for the module
--- @param base_url? string The base URL of the pi server
--- @return PiApiClient
local function create_client(base_url)
  local state = require('pi.state')

  base_url = base_url or state.pi_server and state.pi_server.url

  local api_client = PiApiClient.new(base_url)

  local function on_server_change(_, new_val, _)
    -- NOTE: set base_url here if we can. we still need the check in _call
    -- because the event firing on the server change may not have happened
    -- before a caller is trying to make an api request, so the main benefit
    -- of the subscription is setting base_url to nil when the server goes away
    if new_val and new_val.url then
      api_client.base_url = new_val.url
    else
      api_client.base_url = nil
    end
  end

  state.store.subscribe('pi_server', on_server_change)

  return api_client
end

return {
  new = PiApiClient.new,
  create = create_client,
}
