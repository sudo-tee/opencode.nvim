local M = {}

local config = require('opencode.config')
local log_path = config.logging and config.logging.outfile or vim.fn.stdpath('log') .. '/opencode.log'
local level = config.logging and config.logging.level or 'warn'

local logger = require('plenary.log').new({
  plugin = 'opencode',
  level = level:lower(),
  use_console = false,
  outfile = log_path,
})

local function get_logger()
  return logger
end

function M.debug(msg, ...)
  if not config.logging.enabled then
    return
  end
  get_logger().debug(string.format(msg, ...))
end

function M.info(msg, ...)
  if not config.logging.enabled then
    return
  end
  get_logger().info(string.format(msg, ...))
end

function M.warn(msg, ...)
  if not config.logging.enabled then
    return
  end
  get_logger().warn(string.format(msg, ...))
end

function M.error(msg, ...)
  if not config.logging.enabled then
    return
  end
  get_logger().error(string.format(msg, ...))
end

--- @return string
function M.get_path()
  if not config.logging.enabled then
    return
  end
  return log_path
end

return M
