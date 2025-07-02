local M = {}

---@enum OpencodeConfigKeys
M.ConfigKeys = {
  MODEL = 'model',
}

M.config_file = vim.fn.expand('$HOME/.config/opencode/config.json')

function M.parse_opencode_config()
  local content = vim.fn.readfile(M.config_file)
  local success, json = pcall(vim.fn.json_decode, table.concat(content, '\n'))

  if not success then
    vim.notify('Could not parse opencode config file: ' .. M.config_file, vim.log.levels.ERROR)
    return nil
  end

  return json
end

-- Set a value in the opencode config file
---@param key OpencodeConfigKeys
---@param value any
function M.set_config_value(key, value)
  local conf = M.parse_opencode_config()

  conf[key] = value
  local success, err = pcall(vim.fn.writefile, vim.fn.json_encode(conf), M.config_file)

  if not success then
    vim.notify('Could not write to opencode config file: ' .. err, vim.log.levels.ERROR)
    return false
  end
end

return M
