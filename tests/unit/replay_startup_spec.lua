local assert = require('luassert')

describe('manual replay startup', function()
  it('isolates replay inside configured Neovim from delayed discovery and forced health checks', function()
    local verify = [[
      local Promise = require('opencode.promise')
      require('opencode.services.session_runtime').opencode_ok = function()
        return Promise.new():resolve(true)
      end
      require('opencode').setup()
      local state = require('opencode.state')
      local server_job = require('opencode.server_job')
      local original_ensure = server_job.ensure_server
      local original_set = state.jobs.set_server
      local original_clear = state.jobs.clear_server
      local original_getcwd = vim.fn.getcwd
      local errors = {}
      local notify = vim.notify
      vim.notify = function(message, level, opts)
        if level == vim.log.levels.ERROR then errors[#errors + 1] = message end
        return notify(message, level, opts)
      end
      local replay = require('tests.manual.renderer_replay')
      replay.start({ set_statuscolumn = false })
      local connection = state.opencode_server
      local real = require('opencode.opencode_server').from_custom('http://v2.must-not-be-used')
      local attempted = false
      vim.defer_fn(function()
        state.jobs.set_server(real)
        state.jobs.clear_server()
        attempted = true
      end, 20)
      assert(vim.wait(1000, function() return attempted end))
      assert(state.opencode_server == connection, 'Delayed discovery replaced replay connection')
      assert(server_job.ensure_server({ force_health_check = true }):wait() == connection)
      local config_file = require('opencode.config_file')
      assert(config_file.get_opencode_config():wait().username == 'replay')
      assert(#config_file.get_opencode_providers():wait().providers == 0)
      assert(config_file.get_opencode_project():wait().id == 'project-replay')
      assert(config_file.get_opencode_agents():wait()[1] == 'build')
      assert(#config_file.get_subagents():wait() == 0)
      assert(next(config_file.get_user_commands():wait()) == nil)
      vim.cmd('ReplayLoad tests/data/v2/formatters.json')
      vim.cmd('ReplayAll 10')
      assert(vim.wait(3000, function() return replay.event_index == #replay.events end, 10))
      assert(replay.wait_for_idle())
      local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
      assert(table.concat(lines, '\n'):find('Loaded skill', 1, true))
      assert(#errors == 0, 'Replay emitted errors: ' .. table.concat(errors, '\n'))
      vim.cmd('ReplayExit')
      assert(server_job.ensure_server == original_ensure)
      assert(state.jobs.set_server == original_set)
      assert(state.jobs.clear_server == original_clear)
      assert(vim.fn.getcwd == original_getcwd)
      assert(state.opencode_server == nil)
      print('REPLAY_ISOLATION_OK')
    ]]
    local command = {
      'env',
      '-u',
      'VIM',
      '-u',
      'VIMRUNTIME',
      vim.v.progpath,
      '--headless',
      '-i',
      'NONE',
      '-u',
      'tests/minimal/init.lua',
      '-c',
      'lua ' .. verify,
      '-c',
      'qa!',
    }
    local result = vim.system(command, { text = true }):wait(10000)

    assert.equals(0, result.code, result.stderr)
    local output = result.stdout .. result.stderr
    assert.is_truthy(output:find('REPLAY_ISOLATION_OK', 1, true), output)
  end)

  it('keeps the mock connection after startup callbacks and replays V2 JSON without service discovery', function()
    local probe = [[
      vim.opt.runtimepath:append(vim.fn.getcwd())
      _G.replay_discovery_calls = 0
      require('opencode.services.session_runtime').opencode_ok = function()
        _G.replay_discovery_calls = _G.replay_discovery_calls + 1
      end
    ]]
    local verify = [[
      vim.wait(100, function() return false end, 10)
      assert(_G.replay_discovery_calls == 0, 'Replay startup attempted real service discovery')
      local state = require('opencode.state')
      local connection = state.opencode_server
      assert(connection.protocol == 'v1', 'Replay mock connection was replaced')
      vim.cmd('ReplayLoad tests/data/v2/formatters.json')
      vim.cmd('ReplayAll 0')
      vim.cmd('ReplayFullSession')
      assert(require('tests.manual.renderer_replay').wait_for_idle())
      assert(state.opencode_server == connection, 'Replay changed its connection')
      local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
      assert(table.concat(lines, '\n'):find('Loaded skill', 1, true), 'V2 fixture was not rendered')
      print('REPLAY_STARTUP_OK')
    ]]
    local command = {
      'env',
      '-u',
      'VIM',
      '-u',
      'VIMRUNTIME',
      vim.v.progpath,
      '--headless',
      '-i',
      'NONE',
      '--cmd',
      'lua ' .. probe,
      '-u',
      'tests/manual/init_replay.lua',
      '-c',
      'lua ' .. verify,
      '-c',
      'qa!',
    }
    local result = vim.system(command, { text = true }):wait(10000)

    assert.equals(0, result.code, result.stderr)
    local output = result.stdout .. result.stderr
    assert.is_truthy(output:find('REPLAY_STARTUP_OK', 1, true), output)
  end)
end)
