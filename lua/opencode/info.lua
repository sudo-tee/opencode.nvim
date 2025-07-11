local M = {}

---@enum OpencodeConfigKeys
M.ConfigKeys = {
  MODEL = 'model',
}

M.config_file = vim.fn.expand('$HOME/.config/opencode/config.json')

function M.parse_opencode_config()
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

---@param provider string
---@param model string
function M.set_provider(provider, model)
  local content = table.concat(vim.fn.readfile(M.config_file), '\n')
  local updated = content:gsub('"model": "[^"]+"', string.format('"model": "%s/%s"', provider, model))
  local success, err = pcall(vim.fn.writefile, vim.split(updated, '\n'), M.config_file)

  if not success then
    vim.notify('Could not write to opencode config file: ' .. err, vim.log.levels.ERROR)
    return false
  end
end

return M
