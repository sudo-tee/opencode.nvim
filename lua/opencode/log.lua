local M = {}

local config = require('opencode.config')

local log_path = (config.logging and config.logging.outfile) or vim.fn.stdpath('log') .. '/opencode.log'
local log_levels = { debug = 1, info = 2, warn = 3, error = 4 }
local current_level = log_levels[(config.logging and config.logging.level or 'warn'):lower()] or 3

local function caller_info()
  local level = 2
  while true do
    local info = debug.getinfo(level, 'Sl')
    if not info then return '' end
    local file = info.source:gsub('^@', '')
    if not file:match('/log%.lua$') then
      return string.format(' [%s:%d]', file, info.currentline)
    end
    level = level + 1
  end
end

local function log(level, msg, ...)
  if not config.logging.enabled then
    return
  end
  if log_levels[level] < current_level then
    return
  end
  local line = string.format(
    '[%s] [opencode] [%s]%s %s\n',
    os.date('%Y-%m-%d %H:%M:%S'),
    level:upper(),
    caller_info(),
    string.format(msg, ...)
  )
  local file = io.open(log_path, 'a')
  if file then
    file:write(line)
    file:close()
  end
end

function M.debug(msg, ...)
  log('debug', msg, ...)
end
function M.info(msg, ...)
  log('info', msg, ...)
end
function M.warn(msg, ...)
  log('warn', msg, ...)
end
function M.error(msg, ...)
  log('error', msg, ...)
end

function M.get_path()
  return config.logging.enabled and log_path or nil
end

--- Emit a user-visible notification and write the same message to the log.
--- @param msg string
--- @param level integer vim.log.levels.*
function M.notify(msg, level)
  if level == vim.log.levels.ERROR then
    log('error', msg)
  elseif level == vim.log.levels.WARN then
    log('warn', msg)
  else
    log('info', msg)
  end
  vim.schedule(function()
    vim.notify('[opencode.nvim] ' .. msg, level)
  end)
end

return M
