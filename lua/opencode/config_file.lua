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

function M.get_opencode_modes()
  local cfg = M.parse_opencode_config()
  if not cfg then
    return {}
  end

  local modes = {}
  for mode, _ in pairs(cfg.mode or {}) do
    table.insert(modes, mode)
  end

  for _, mode in ipairs({ 'build', 'plan' }) do
    if not vim.tbl_contains(modes, mode) then
      table.insert(modes, mode)
    end
  end

  return modes
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
