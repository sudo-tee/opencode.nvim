local state = require('opencode.state')
local M = {}

---@enum OpencodeConfigKeys
M.ConfigKeys = {
  MODEL = 'model',
}

function M.parse_opencode_config()
  local home = vim.uv.os_homedir()
  M.config_file = home .. '/.config/opencode/config.json'

  if vim.fn.filereadable(M.config_file) == 0 then
    vim.notify('Opencode config file not found: ' .. M.config_file, vim.log.levels.WARN)
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
