local Promise = require('opencode.promise')
local sha1 = require('opencode.sha1')
local util = require('opencode.util')
local server_job = require('opencode.server_job')
local M = {
  config_promise = nil,
  project_promise = nil,
  providers_promise = nil,
}
local cache_connection

local function sync_cache_connection()
  local connection = require('opencode.state').opencode_server
  if connection ~= cache_connection then
    cache_connection = connection
    M.config_promise = nil
    M.project_promise = nil
    M.providers_promise = nil
  end
  return connection
end

local resource = Promise.async(function(name, directory)
  local state = require('opencode.state')
  local connection = server_job.ensure_server():await()
  sync_cache_connection()
  local operation = connection and connection.operations and connection.operations[name]
  if type(operation) ~= 'function' then
    error('Connection does not support ' .. name)
  end
  return operation(
    connection,
    { directory = directory or state.current_cwd or vim.fn.getcwd() },
    util.apply_path_map,
    util.apply_reverse_path_map
  )
end)

---@type fun(): Promise<OpencodeConfigFile|nil>
M.get_opencode_config = Promise.async(function()
  sync_cache_connection()
  if not M.config_promise then
    M.config_promise = Promise.retry(function()
      return resource('get_config')
    end, 3, 500)
  end
  local ok, result = pcall(function()
    return M.config_promise:await()
  end)

  if not ok then
    M.config_promise = nil
    vim.notify('Error fetching Opencode config: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result
end)

---@type fun(directory?: string): Promise<OpencodeProject|nil>
M.get_opencode_project = Promise.async(function(directory)
  sync_cache_connection()
  if directory then
    return resource('get_current_project', directory):await()
  end
  if not M.project_promise then
    M.project_promise = Promise.retry(function()
      return resource('get_current_project')
    end, 3, 500)
  end
  local ok, result = pcall(function()
    return M.project_promise:await()
  end)
  if not ok then
    M.project_promise = nil
    vim.notify('Error fetching Opencode project: ' .. vim.inspect(result), vim.log.levels.ERROR)
    return nil
  end

  return result --[[@as OpencodeProject|nil]]
end)

---Get the snapshot storage path for the current workspace
---Matches opencode's Global.Path.data + "snapshot" + projectId + Hash.fast(worktree)
---Can be overridden via config.snapshot_path (base path, project_id and worktree_hash are appended)
---@type fun(directory?: string): Promise<string>
M.get_workspace_snapshot_path = Promise.async(function(directory)
  local cwd = directory or vim.fn.getcwd()
  local project = M.get_opencode_project(cwd):await() --[[@as OpencodeProject|nil]]
  if not project then
    return ''
  end
  local data_home = require('opencode.config').snapshot_path
  if not data_home or data_home == '' then
    data_home = vim.uv.os_getenv('XDG_DATA_HOME')
    if not data_home or data_home == '' then
      data_home = vim.uv.os_homedir() .. '/.local/share'
    end
    data_home = vim.fs.joinpath(data_home, 'opencode')
  end
  local worktree_hash = sha1(cwd)
  if not worktree_hash then
    return ''
  end
  local path = vim.fs.joinpath(data_home, 'snapshot', project.id, worktree_hash)
  return vim.fs.normalize(path)
end)

---@return Promise<OpencodeProvidersResponse|nil>
function M.get_opencode_providers()
  sync_cache_connection()
  if not M.providers_promise then
    M.providers_promise = resource('get_model_catalog')
  end
  return M.providers_promise:catch(function(err)
    vim.notify('Error fetching Opencode providers: ' .. vim.inspect(err), vim.log.levels.ERROR)
    M.providers_promise = nil
    return nil
  end)
end

--- Get model information for a specific provider and model
--- @param provider string Provider ID
--- @param model string Model ID
--- @return OpencodeModel|nil Model information with variants
M.get_model_info = function(provider, model)
  local providers_response = M.get_opencode_providers():peek()

  local providers = providers_response and providers_response.providers or {}

  local filtered_providers = vim.tbl_filter(function(p)
    return p.id == provider
  end, providers)

  if #filtered_providers == 0 then
    return nil
  end

  return filtered_providers[1] and filtered_providers[1].models and filtered_providers[1].models[model] or nil
end

---@type fun(): Promise<string[]>
M.get_opencode_agents = Promise.async(function()
  return resource('list_primary_agents'):await() or {}
end)

---@type fun(): Promise<string[]>
M.get_subagents = Promise.async(function()
  return resource('list_subagents'):await() or {}
end)

---@type fun(): Promise<table<string, table>|nil>
M.get_user_commands = Promise.async(function()
  return resource('get_user_commands'):await()
end)

---Does this opencode user command take arguments?
---@param command OpencodeCommand
---@return boolean
function M.command_takes_arguments(command)
  return command.template and command.template:find('$ARGUMENTS') ~= nil or false
end

return M
