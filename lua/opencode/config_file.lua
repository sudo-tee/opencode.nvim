local state = require('opencode.state')
local config = require('opencode.config').get()

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
  if vim.fn.filereadable(M.config_file) == 0 then
    vim.notify('Opencode config file not found', vim.log.levels.ERROR)
    return nil
  end
  local content = vim.fn.readfile(M.config_file)
  local success, json = pcall(vim.json.decode, table.concat(content, '\n'))

  if not success then
    vim.notify('Could not parse opencode config file: ' .. M.config_file, vim.log.levels.ERROR)
    return nil
  end

  return json
end

function M.get_opencode_modes()
  local config = M.parse_opencode_config()
  if not config then
    return {}
  end

  local modes = {}
  for mode, _ in pairs(config.mode or {}) do
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
  local config = M.parse_opencode_config()
  if not config or not config.mcp then
    return nil
  end

  return config.mcp
end

---@param provider string
---@param model string
function M.set_provider(provider, model)
  local model_str = string.format('%s/%s', provider, model)
  local content = table.concat(vim.fn.readfile(M.config_file), '\n')
  local updated = content:gsub('"model": "[^"]+"', string.format('"model": "%s"', model_str))
  local success, err = pcall(vim.fn.writefile, vim.split(updated, '\n'), M.config_file)

  state.current_model = model_str

  if not success then
    vim.notify('Could not write to opencode config file: ' .. err, vim.log.levels.ERROR)
    return false
  end
end

return M
