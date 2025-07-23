-- /lua/opencode/models.lua

local M = {
  __cache = {
    models = nil,
  },
}

local url = 'https://models.dev/api.json'
local cache_file = vim.fn.stdpath('cache') .. '/opencode/opencode_models.json'
local curl = require('plenary.curl')

function M.setup()
  local cache_dir = vim.fn.stdpath('cache') .. '/opencode'
  if vim.fn.isdirectory(cache_dir) == 0 then
    vim.fn.mkdir(cache_dir, 'p')
  end
  M.load()
end

-- Download models.json and write to cache
function M.download_models()
  vim.notify('[Opencode.nvim] Downloading models from ' .. url .. '...', vim.log.levels.INFO)
  local result = curl.get(url, { timeout = 10000 })
  if result.status ~= 200 or not result.body then
    error('Failed to download models.json: HTTP status ' .. tostring(result.status))
  end
  local ok = vim.fn.writefile({ result.body }, cache_file)
  if ok ~= 0 then
    error('Failed to write models.json to cache: ' .. cache_file)
  end
end

-- Read models.json from cache
function M.read_cache()
  local ok, lines = pcall(vim.fn.readfile, cache_file)
  if not ok or not lines or #lines == 0 then
    return nil
  end
  return table.concat(lines, '\n')
end

function M.load()
  local raw = M.read_cache()
  if not raw then
    M.download_models()
    raw = M.read_cache()
    if not raw then
      error('Failed to get models.json')
    end
  end
  M.__cache.models = vim.json.decode(raw)
end

function M.update_cache()
  M.download_models()
  M.load()
end

function M.get_all()
  if not M.__cache.models then
    M.load()
  end
  return M.__cache.models
end

function M.get(provider, model)
  if not M.__cache.models then
    M.load()
  end
  return M.__cache.models and M.__cache.models[provider] and M.__cache.models[provider].models[model] or nil
end

return M
