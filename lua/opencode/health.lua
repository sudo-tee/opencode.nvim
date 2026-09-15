local M = {}

local health = vim.health or require('health')
local config = require('opencode.config')
local util = require('opencode.util')

local function command_exists(cmd)
  return vim.fn.executable(cmd) == 1
end

local function get_opencode_version()
  if not command_exists(config.opencode_executable) then
    return nil, 'opencode command not found'
  end

  local result = vim.system({ config.opencode_executable, '--version' }):wait()
  if result.code ~= 0 then
    return nil, 'Failed to get opencode version: ' .. (result.stderr or 'unknown error')
  end

  local out = (result.stdout or ''):gsub('%s+$', '')
  local version = out:match('(%d+%.%d+%.%d+)') or out
  return version, nil
end

local function check_opencode_cli()
  health.start('OpenCode CLI')

  local state = require('opencode.state')
  local required_version = state.required_version

  if not command_exists(config.opencode_executable) then
    health.error('opencode command not found', {
      'Install opencode CLI from: https://docs.opencode.com/installation',
      'Ensure opencode is in your PATH',
    })
    return
  end

  health.ok('opencode command found')

  local version, err = get_opencode_version()
  if not version then
    health.error('Could not determine opencode version: ' .. (err or 'unknown error'))
    return
  end

  if not util.is_version_greater_or_equal(version, required_version) then
    health.error(string.format('Unsupported opencode CLI version: %s (requires >= %s)', version, required_version), {
      'Update opencode CLI to the latest version',
      'Visit: https://docs.opencode.com/installation',
    })
    return
  end

  health.ok(string.format('opencode CLI version: %s (>= %s required)', version, required_version))
end

local function check_opencode_server()
  health.start('OpenCode Server')
  local server_job = require('opencode.server_job')
  local state = require('opencode.state')
  local previous_connection = state.opencode_server
  local ok, server = pcall(function()
    return server_job.ensure_server():wait()
  end)
  if not ok or not server or not server.url or not server.protocol then
    health.error('Failed to establish an authenticated opencode connection: ' .. vim.inspect(server))
    return
  end

  health.ok(string.format('opencode %s server %s is reachable at %s', server.protocol, server.version, server.url))
  if server:can_release_process() then
    health.info('this Connection may release its local server process')
  elseif server.port then
    health.info('this Connection closes client resources only; the configured server process remains running')
  else
    health.info('this Connection closes client resources only; the native service remains running')
  end
  local result_ok, result = pcall(function()
    return require('opencode.config_file').get_opencode_config():wait()
  end)
  if result_ok and result ~= nil then
    health.ok('opencode server configuration available')
  else
    health.error('opencode server configuration request failed: ' .. vim.inspect(result))
  end

  local created_for_check = previous_connection == nil and state.opencode_server == server
  if created_for_check then
    state.jobs.clear_server()
    local close_ok, close_promise = pcall(server.close, server)
    if close_ok and close_promise then
      close_promise:wait()
      if close_promise:is_resolved() then
        health.ok('opencode connection closed successfully')
      else
        health.error('Failed to close opencode connection')
      end
    else
      health.error('Failed to close opencode connection: ' .. vim.inspect(close_promise))
    end
  else
    health.info('opencode server connection left running')
  end
end

local function check_configuration()
  health.start('Configuration')

  local config_ok, config = pcall(require, 'opencode.config')
  if not config_ok then
    health.error('Failed to load opencode configuration')
    return
  end

  ---@cast config OpencodeConfig

  local valid_positions = { 'left', 'right', 'top', 'bottom', 'current' }
  if not vim.tbl_contains(valid_positions, config.ui.position) then
    health.warn(
      string.format('Invalid UI position: %s', config.ui.position),
      { 'Valid positions: ' .. table.concat(valid_positions, ', ') }
    )
  else
    health.ok(string.format('UI position: %s', config.ui.position))
  end

  if config.ui.window_width <= 0 or config.ui.window_width > 1 then
    health.warn(
      string.format('Invalid window width: %s', config.ui.window_width),
      { 'Window width should be between 0 and 1 (percentage of screen)' }
    )
  else
    health.ok(string.format('Window width: %s', config.ui.window_width))
  end

  local min_height = config.ui.input.min_height
  local max_height = config.ui.input.max_height
  if type(min_height) ~= 'number' or type(max_height) ~= 'number' then
    health.warn(
      'Input min/max height configuration incomplete',
      { 'Set both ui.input.min_height and ui.input.max_height to enable auto-resize' }
    )
  else
    if min_height <= 0 or min_height > 1 then
      health.warn(
        string.format('Invalid input min height: %s', min_height),
        { 'Input min height should be between 0 and 1 (percentage of screen)' }
      )
    else
      health.ok(string.format('Input min height: %s', min_height))
    end

    if max_height <= 0 or max_height > 1 then
      health.warn(
        string.format('Invalid input max height: %s', max_height),
        { 'Input max height should be between 0 and 1 (percentage of screen)' }
      )
    else
      health.ok(string.format('Input max height: %s', max_height))
    end

    if min_height > max_height then
      health.warn(
        'Input min height exceeds max height',
        { 'Ensure ui.input.min_height is less than or equal to ui.input.max_height' }
      )
    end
  end

  health.ok('Configuration loaded successfully')
end

local function check_environment()
  health.start('Environment')

  local git_dir = vim.fn.system('git rev-parse --git-dir 2>/dev/null'):gsub('\n', '')
  if vim.v.shell_error == 0 and git_dir ~= '' then
    health.ok('Git repository detected')
  else
    health.info('Not in a git repository (optional but recommended for opencode)')
  end

  local cwd = vim.fn.getcwd()
  if cwd and cwd ~= '' then
    health.ok(string.format('Working directory: %s', cwd))
  else
    health.warn('Could not determine current working directory')
  end
end

local function check_integrations()
  health.start('Optional Integrations')

  local telescope_ok, _ = pcall(require, 'telescope')
  if telescope_ok then
    health.ok('telescope.nvim found (enhanced file picker available)')
  else
    health.info('telescope.nvim not found (using vim.ui.select for file picker)')
  end

  local mini_pick_ok, _ = pcall(require, 'mini.pick')
  if mini_pick_ok then
    health.ok('mini.pick found (enhanced file picker available)')
  else
    health.info('mini.pick not found')
  end

  local fzf_lua_ok, _ = pcall(require, 'fzf-lua')
  if fzf_lua_ok then
    health.ok('fzf-lua found (enhanced file picker available)')
  else
    health.info('fzf-lua not found')
  end

  local snacks_ok, _ = pcall(require, 'snacks')
  if snacks_ok then
    health.ok('snacks.nvim found (enhanced file picker available)')
  else
    health.info('snacks.nvim not found')
  end

  local blink_ok, _ = pcall(require, 'blink.cmp')
  if blink_ok then
    health.ok('blink found (enhanced completion available)')
  else
    health.info('blink not found')
  end

  local cmp_ok, _ = pcall(require, 'cmp')
  if cmp_ok then
    health.ok('nvim-cmp found (enhanced completion available)')
  else
    health.info('nvim-cmp not found')
  end

  if not blink_ok and not cmp_ok then
    health.warn('No completion engine found, will fallback to vim_complete (consider installing blink or nvim-cmp)')
  end
end

local function check_finder_cli_tools()
  health.start('Finder CLI Tools')

  local find_cmds = { 'fd', 'rg', 'git' }
  local found = false
  for _, cmd in ipairs(find_cmds) do
    if command_exists(cmd) then
      health.ok(string.format('Found file finder command: %s', cmd))
      found = true
      break
    end
  end

  if not found then
    health.warn('No file finder command found (consider installing fd, rg, git, or find)')
  end
end

function M.check()
  check_opencode_cli()
  check_opencode_server()
  check_configuration()
  check_environment()
  check_integrations()
  check_finder_cli_tools()
end

return M
