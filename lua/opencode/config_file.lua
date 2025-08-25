local state = require('opencode.state')
local config = require('opencode.config').get()
local OrderedJson = require('opencode.ordered_json')

local M = {}

---@enum OpencodeConfigKeys
M.ConfigKeys = {
  MODEL = 'model',
}

local config_files_names = {
  'config.json',
  'opencode.json',
}

function M.setup()
  local home = vim.uv.os_homedir()
  local custom_path = config.config_file_path

  if custom_path then
    if vim.fn.filereadable(custom_path) == 1 then
      M.config_file = custom_path
      return
    end
    vim.notify('Opencode config file provided in config_file_path not found: ' .. custom_path, vim.log.levels.WARN)
  end

  for _, name in ipairs(config_files_names) do
    local path = home .. '/.config/opencode/' .. name
    if vim.fn.filereadable(path) == 1 then
      M.config_file = path
      return
    end
  end

  vim.notify('Opencode config file not found in expected locations', vim.log.levels.ERROR)
end

function M.parse_opencode_config()
  local json = OrderedJson.new():read(M.config_file)
  if not json or not json.data then
    vim.notify('Failed to parse opencode config file', vim.log.levels.ERROR)
    return nil
  end

  return json.data
end

---@param dir string
---@param list string[]
local function add_agents_from(dir, list)
  if vim.fn.isdirectory(dir) ~= 1 then
    return
  end
  local ok, files = pcall(vim.fn.readdir, dir)
  if not ok then
    return
  end
  for _, file in ipairs(files) do
    local name = file:match('^(.*)%.md$')
    if name then
      if not vim.tbl_contains(list, name) then
        table.insert(list, name)
      end
    end
  end
end

local function add_user_commands_from(dir, list)
  if vim.fn.isdirectory(dir) ~= 1 then
    return
  end
  local ok, files = pcall(vim.fn.readdir, dir)
  if not ok then
    return
  end
  for _, file in ipairs(files) do
    local name = file:match('^(.*)%.md$')
    if name then
      local cmd = { name = name, path = dir .. '/' .. file }
      if not vim.tbl_contains(list, cmd) then
        table.insert(list, cmd)
      end
    end
  end
end

function M.get_opencode_agents()
  local home = vim.uv.os_homedir()
  local cfg = M.parse_opencode_config()
  if not cfg then
    return {}
  end

  local agents = {}
  for mode, _ in pairs(cfg.agent or {}) do
    table.insert(agents, mode)
  end

  for _, mode in ipairs({ 'build', 'plan' }) do
    if not vim.tbl_contains(agents, mode) then
      table.insert(agents, mode)
    end
  end

  add_agents_from(home .. '/.config/opencode/agent', agents)
  add_agents_from('.opencode/agent', agents)

  return agents
end

function M.get_user_commands()
  local commands = {}

  add_user_commands_from(vim.uv.os_homedir() .. '/.config/opencode/command', commands)
  add_user_commands_from('.opencode/command', commands)
  return commands
end

function M.get_mcp_servers()
  local cfg = M.parse_opencode_config()
  if not cfg or not cfg.mcp then
    return nil
  end

  return cfg.mcp
end

---@param provider string
---@param model string
function M.set_model(provider, model)
  local model_str = string.format('%s/%s', provider, model)
  local encoder = OrderedJson.new()
  local json = encoder:read(M.config_file)
  if not json or type(json.data) ~= 'table' then
    vim.notify('Failed to parse opencode config file for model update', vim.log.levels.ERROR)
    return false
  end

  json.data.model = model_str
  state.current_model = model_str

  local updated = encoder:encode(json)
  local success, err = pcall(vim.fn.writefile, vim.split(updated, '\n'), M.config_file)

  vim.cmd('checktime')

  if not success then
    vim.notify('Could not write to opencode config file: ' .. err, vim.log.levels.ERROR)
    return false
  end
end

return M
