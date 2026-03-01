local server_job = require('opencode.server_job')
local state = require('opencode.state')
local util = require('opencode.util')

local function encode_query_value(value)
	return tostring(value):gsub('([^%w%-_%.~])', function(ch)
		return string.format('%%%02X', string.byte(ch))
	end)
end

--- @class OpencodeApiClient
--- @field base_url string The base URL of the opencode server
local OpencodeApiClient = {}
OpencodeApiClient.__index = OpencodeApiClient

--- Create a new API client instance
--- @param base_url? string The base URL of the opencode server
--- @return OpencodeApiClient
function OpencodeApiClient.new(base_url)
	return setmetatable({
		base_url = base_url and base_url:gsub('/$', ''), -- Remove trailing slash
	}, OpencodeApiClient)
end

---Ensure that base_url is set. Even thought we're subscribed to
---state.opencode_server, we still need this check because
---it's possible someone will try to make an api call in their event
---handler (e.g. event_manager or header)
---@return boolean
function OpencodeApiClient:_ensure_base_url()
	-- NOTE: eventhough we're subscribed opencode_server, we need this check for
	-- base_url because the notification about opencode_server being set to
	-- non-nil my not have gotten to us in time
	if self.base_url then
		return true
	end

	local state = require('opencode.state')

	if not state.opencode_server then
		-- this is last resort - try to start the server and could be blocking
		state.opencode_server = server_job.ensure_server():wait() --[[@as OpencodeServer]]
		-- shouldn't normally happen but prevents error in replay tester
		if not state.opencode_server then
			return false
		end
	end

	if not state.opencode_server.url then
		state.opencode_server:get_spawn_promise():wait()
		if not state.opencode_server.url then
			return false
		end
	end

	self.base_url = state.opencode_server.url:gsub('/$', '')
	return true
end

--- Make a typed API call
--- @param endpoint string The API endpoint path
--- @param method string|nil HTTP method (default: 'GET')
--- @param body table|nil|boolean Request body
--- @param query table|nil Query parameters
--- @return Promise<any> promise
function OpencodeApiClient:_call(endpoint, method, body, query)
	if not self:_ensure_base_url() then
		return require('opencode.promise').new():reject('No server base url')
	end
	local url = self.base_url .. endpoint

	if query then
		if not query.directory then
			query.directory = state.current_cwd or vim.fn.getcwd()
		end

		local normalized_query = vim.deepcopy(query)
		if normalized_query.directory then
			normalized_query.directory = util.to_server_path(normalized_query.directory)
		end
		if normalized_query.path then
			normalized_query.path = util.to_server_path(normalized_query.path)
		end

		local params = {}

		for k, v in pairs(normalized_query) do
			if v ~= nil then
				table.insert(params, k .. '=' .. encode_query_value(v))
			end
		end

		if #params > 0 then
			url = url .. '?' .. table.concat(params, '&')
		end
	end

	return server_job.call_api(url, method, body)
end

-- Project endpoints

--- List all projects
--- @param directory string|nil Directory path
--- @return Promise<OpencodeProject[]>
function OpencodeApiClient:list_projects(directory)
	return self:_call('/project', 'GET', nil, { directory = directory })
end

--- Get the current project
--- @param directory string|nil Directory path
--- @return Promise<OpencodeProject>
function OpencodeApiClient:get_current_project(directory)
	return self:_call('/project/current', 'GET', nil, { directory = directory })
end

-- Config endpoints

--- Get config info
--- @param directory string|nil Directory path
--- @return Promise<OpencodeConfig>
function OpencodeApiClient:get_config(directory)
	return self:_call('/config', 'GET', nil, { directory = directory })
end

--- Update config
--- @param config OpencodeConfig Config object to update
--- @param directory string|nil Directory path
--- @return Promise<OpencodeConfig>
function OpencodeApiClient:update_config(config, directory)
	return self:_call('/config', 'PATCH', config, { directory = directory })
end

--- List all providers
--- @param directory string|nil Directory path
--- @return Promise<OpencodeProvidersResponse>
function OpencodeApiClient:list_providers(directory)
	return self:_call('/config/providers', 'GET', nil, { directory = directory })
end

--- Get the current path
--- @param directory string|nil Directory path
--- @return Promise<OpencodePath>
function OpencodeApiClient:get_path(directory)
	return self:_call('/path', 'GET', nil, { directory = directory })
end

-- Session endpoints

--- List all sessions
--- @param directory string|nil Directory path
--- @return Promise<Session[]>
function OpencodeApiClient:list_sessions(directory)
	return self:_call('/session', 'GET', nil, { directory = directory })
end

--- Create a new session
--- @param session_data {parentID?: string, title?: string}|nil|boolean Session creation data
--- @param directory string|nil  Directory path
--- @return Promise<Session>
function OpencodeApiClient:create_session(session_data, directory)
	return self:_call('/session', 'POST', session_data or false, { directory = directory })
end

--- Get session by ID
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:get_session(id, directory)
	return self:_call('/session/' .. id, 'GET', nil, { directory = directory })
end

--- Delete a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:delete_session(id, directory)
	return self:_call('/session/' .. id, 'DELETE', nil, { directory = directory })
end

--- Update session properties
--- @param id string Session ID (required)
--- @param session_update {title?: string} Session update data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:update_session(id, session_update, directory)
	return self:_call('/session/' .. id, 'PATCH', session_update, { directory = directory })
end

--- Get a session's children
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session[]>
function OpencodeApiClient:get_session_children(id, directory)
	return self:_call('/session/' .. id .. '/children', 'GET', nil, { directory = directory })
end

--- Initialize session (analyze app and create AGENTS.md)
--- @param id string Session ID (required)
--- @param init_data {messageID: string, providerID: string, modelID: string} Initialization data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:init_session(id, init_data, directory)
	return self:_call('/session/' .. id .. '/init', 'POST', init_data, { directory = directory })
end

--- Abort a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:abort_session(id, directory)
	return self:_call('/session/' .. id .. '/abort', 'POST', nil, { directory = directory })
end

--- Share a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:share_session(id, directory)
	return self:_call('/session/' .. id .. '/share', 'POST', nil, { directory = directory })
end

--- Unshare a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:unshare_session(id, directory)
	return self:_call('/session/' .. id .. '/share', 'DELETE', nil, { directory = directory })
end

--- Summarize a session
--- @param id string Session ID (required)
--- @param summary_data {providerID: string, modelID: string} Summary data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:summarize_session(id, summary_data, directory)
	return self:_call('/session/' .. id .. '/summarize', 'POST', summary_data, { directory = directory })
end

--- Fork an existing session at a specific message
--- @param id string Session ID (required)
--- @param fork_data {messageID?: string}|nil Fork data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:fork_session(id, fork_data, directory)
	return self:_call('/session/' .. id .. '/fork', 'POST', fork_data, { directory = directory })
end

-- Message endpoints

--- List messages for a session
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<OpencodeMessage[]>
function OpencodeApiClient:list_messages(id, directory)
	return self:_call('/session/' .. id .. '/message', 'GET', nil, { directory = directory })
end

--- Create and send a new message to a session
--- @param id string Session ID (required)
--- @param message_data {messageID?: string, model?: {providerID: string, modelID: string}, agent?: string, variant?: string, system?: string, tools?: table<string, boolean>, parts: OpencodeMessagePart[]} Message creation data
--- @param directory string|nil Directory path
--- @return Promise<{info: MessageInfo, parts: OpencodeMessagePart[]}>
function OpencodeApiClient:create_message(id, message_data, directory)
	return self:_call('/session/' .. id .. '/message', 'POST', message_data, { directory = directory })
end

--- Get a message from a session
--- @param id string Session ID (required)
--- @param messageID string Message ID (required)
--- @param directory string|nil Directory path
--- @return Promise<OpencodeMessage>
function OpencodeApiClient:get_message(id, messageID, directory)
	return self:_call('/session/' .. id .. '/message/' .. messageID, 'GET', nil, { directory = directory })
end

--- Send a command to a session
--- @param id string Session ID (required)
--- @param command_data {messageID?: string, agent?: string, model?: string, arguments: string, command: string} Command data
--- @param directory string|nil Directory path
--- @return Promise<OpencodeMessage>
function OpencodeApiClient:send_command(id, command_data, directory)
	return self:_call('/session/' .. id .. '/command', 'POST', command_data, { directory = directory })
end

--- Run a shell command
--- @param id string Session ID (required)
--- @param shell_data {agent?: string, command: string} Shell command data
--- @param directory string|nil Directory path
--- @return Promise<MessageInfo>
function OpencodeApiClient:run_shell(id, shell_data, directory)
	return self:_call('/session/' .. id .. '/shell', 'POST', shell_data, { directory = directory })
end

--- Revert a message
--- @param id string Session ID (required)
--- @param revert_data {messageID: string, partID?: string} Revert data
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:revert_message(id, revert_data, directory)
	return self:_call('/session/' .. id .. '/revert', 'POST', revert_data, { directory = directory })
end

--- Restore all reverted messages
--- @param id string Session ID (required)
--- @param directory string|nil Directory path
--- @return Promise<Session>
function OpencodeApiClient:unrevert_messages(id, directory)
	return self:_call('/session/' .. id .. '/unrevert', 'POST', nil, { directory = directory })
end

--- Respond to a permission request
--- @param id string Session ID (required)
--- @param permissionID string Permission ID (required)
--- @param response_data {response: "once"|"always"|"reject"} Response data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:respond_to_permission(id, permissionID, response_data, directory)
	return self:_call(
		'/session/' .. id .. '/permissions/' .. permissionID,
		'POST',
		response_data,
		{ directory = directory }
	)
end

--- List all commands
--- @param directory string|nil Directory path
--- @return Promise<OpencodeCommand[]>
function OpencodeApiClient:list_commands(directory)
	return self:_call('/command', 'GET', nil, { directory = directory })
end

--- Find text in files
--- @param pattern string Search pattern (required)
--- @param directory string|nil Directory path
--- @return Promise<table[]> Search results
function OpencodeApiClient:find_text(pattern, directory)
	return self:_call('/find', 'GET', nil, {
		pattern = pattern,
		directory = directory,
	})
end

--- Find files
--- @param query string File search query (required)
--- @param directory string|nil Directory path
--- @return Promise<string[]> File paths
function OpencodeApiClient:find_files(query, directory)
	return self:_call('/find/file', 'GET', nil, {
		query = query,
		directory = directory,
	})
end

--- Find workspace symbols
--- @param query string Symbol search query (required)
--- @param directory string|nil Directory path
--- @return Promise<table[]> Symbols
function OpencodeApiClient:find_symbols(query, directory)
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
function OpencodeApiClient:list_files(path, directory)
	return self:_call('/file', 'GET', nil, {
		path = path,
		directory = directory,
	})
end

--- Read a file
--- @param path string File path (required)
--- @param directory string|nil Directory path
--- @return Promise<table>
function OpencodeApiClient:read_file(path, directory)
	return self:_call('/file/content', 'GET', nil, {
		path = path,
		directory = directory,
	})
end

--- Get file status
--- @param directory string|nil Directory path
--- @return Promise<table[]>
function OpencodeApiClient:get_file_status(directory)
	return self:_call('/file/status', 'GET', nil, { directory = directory })
end

-- Log endpoints

--- Write a log entry to the server logs
--- @param log_data {service: string, level: "debug"|"info"|"error"|"warn", message: string, extra?: table<string, any>} Log entry data
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:write_log(log_data, directory)
	return self:_call('/log', 'POST', log_data, { directory = directory })
end

-- Agent endpoints

--- List all agents
--- @param directory string|nil Directory path
--- @return Promise<OpencodeAgent[]>
function OpencodeApiClient:list_agents(directory)
	return self:_call('/agent', 'GET', nil, { directory = directory })
end

-- Question endpoints

--- List pending questions
--- @param directory string|nil Directory path
--- @return Promise<OpencodeQuestionRequest[]>
function OpencodeApiClient:list_questions(directory)
	return self:_call('/question', 'GET', nil, { directory = directory })
end

--- Reply to a question
--- @param requestID string Question request ID (required)
--- @param answers string[][] Array of answers (each answer is array of selected labels)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:reply_question(requestID, answers, directory)
	return self:_call('/question/' .. requestID .. '/reply', 'POST', { answers = answers }, { directory = directory })
end

--- Reject a question
--- @param requestID string Question request ID (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:reject_question(requestID, directory)
	return self:_call('/question/' .. requestID .. '/reject', 'POST', nil, { directory = directory })
end

--- Subscribe to events (streaming)
--- @param directory string|nil Directory path
--- @param on_event fun(event: table) Event callback
--- @return table The streaming job handle
function OpencodeApiClient:subscribe_to_events(directory, on_event)
	self:_ensure_base_url()
	local url = self.base_url .. '/event'
	directory = util.to_server_path(directory)
	if directory then
		url = url .. '?directory=' .. encode_query_value(directory)
	end

	return server_job.stream_api(url, 'GET', nil, function(chunk)
		-- strip data: prefix if present
		chunk = chunk:gsub('^data:%s*', '')
		local ok, event = pcall(vim.json.decode, vim.trim(chunk))
		if ok and event then
			on_event(event --[[@as table]])
		end
	end)
end

-- Tool endpoints

--- List all tool IDs (including built-in and dynamically registered)
--- @param directory string|nil Directory path
--- @return Promise<string[]>
function OpencodeApiClient:list_tool_ids(directory)
	return self:_call('/experimental/tool/ids', 'GET', nil, { directory = directory })
end

--- List tools with JSON schema parameters for a provider/model
--- @param provider string Provider name (required)
--- @param model string Model name (required)
--- @param directory string|nil Directory path
--- @return Promise<OpencodeToolList>
function OpencodeApiClient:list_tools(provider, model, directory)
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
function OpencodeApiClient:list_mcp_servers(directory)
	return self:_call('/mcp', 'GET', nil, { directory = directory })
end

--- Connect an MCP server
--- @param name string MCP server name (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:connect_mcp(name, directory)
	if not name or name == '' then
		return require('opencode.promise').new():reject('MCP server name is required')
	end
	return self:_call('/mcp/' .. name .. '/connect', 'POST', nil, { directory = directory })
end

--- Disconnect an MCP server
--- @param name string MCP server name (required)
--- @param directory string|nil Directory path
--- @return Promise<boolean>
function OpencodeApiClient:disconnect_mcp(name, directory)
	if not name or name == '' then
		return require('opencode.promise').new():reject('MCP server name is required')
	end
	return self:_call('/mcp/' .. name .. '/disconnect', 'POST', nil, { directory = directory })
end

--- Create a factory function for the module
--- @param base_url? string The base URL of the opencode server
--- @return OpencodeApiClient
local function create_client(base_url)
	local state = require('opencode.state')

	base_url = base_url or state.opencode_server and state.opencode_server.url

	local api_client = OpencodeApiClient.new(base_url)

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

	state.subscribe('opencode_server', on_server_change)

	return api_client
end

return {
	new = OpencodeApiClient.new,
	create = create_client,
}
