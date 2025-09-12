local api = require('opencode.api')
local core = require('opencode.core')
local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local stub = require('luassert.stub')

describe('opencode.api', function()
  local created_commands = {}

  before_each(function()
    created_commands = {}
    stub(vim.api, 'nvim_create_user_command').invokes(function(name, fn, opts)
      table.insert(created_commands, {
        name = name,
        fn = fn,
        opts = opts,
      })
    end)
    stub(core, 'open')
    stub(core, 'run')
    stub(core, 'stop')
    stub(core, 'send_message')
    stub(ui, 'close_windows')
  end)

  after_each(function()
    -- luassert.stub automatically restores originals after each test
  end)

  describe('commands table', function()
    it('contains the expected commands with proper structure', function()
      local expected_commands = {
        'open_input',
        'open_input_new_session',
        'open_output',
        'close',
        'stop',
        'run',
        'run_new_session',
      }

      for _, cmd_name in ipairs(expected_commands) do
        local cmd = api.commands[cmd_name]
        assert.truthy(cmd, 'Command ' .. cmd_name .. ' should exist')
        assert.truthy(cmd.name, 'Command should have a name')
        assert.truthy(cmd.desc, 'Command should have a description')
        assert.is_function(cmd.fn, 'Command should have a function')
      end
    end)
  end)

  describe('setup', function()
    it('registers all commands', function()
      api.setup()

      local expected_count = 0
      for _ in pairs(api.commands) do
        expected_count = expected_count + 1
      end

      assert.equal(expected_count, #created_commands, 'All commands should be registered')

      for i, cmd in ipairs(created_commands) do
        local found = false
        for _, def in pairs(api.commands) do
          if def.name == cmd.name then
            found = true
            assert.equal(def.desc, cmd.opts.desc, 'Command should have correct description')
            break
          end
        end
        assert.truthy(found, 'Command ' .. cmd.name .. ' should be defined in commands table')
      end
    end)

    it('sets up command functions that call the correct core functions', function()
      -- We'll use the real vim.api.nvim_create_user_command implementation to store functions
      local stored_fns = {}
      vim.api.nvim_create_user_command = function(name, fn, _)
        stored_fns[name] = fn
      end

      -- All core/ui methods are stubbed in before_each; no need for local spies or wrappers

      api.setup()

      -- Test open_input command
      stored_fns['OpencodeOpenInput']()
      assert.stub(core.open).was_called()
      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input' })

      -- Test open_input_new_session command
      stored_fns['OpencodeOpenInputNewSession']()
      assert.stub(core.open).was_called()
      assert.stub(core.open).was_called_with({ new_session = true, focus = 'input' })

      -- Test stop command
      stored_fns['OpencodeStop']()
      assert.stub(core.stop).was_called()

      -- Test close command
      stored_fns['OpencodeClose']()
      assert.stub(ui.close_windows).was_called()

      -- Test run command
      local test_args = { args = 'test prompt' }
      stored_fns['OpencodeRun'](test_args)
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt', {
        new_session = false,
        focus = 'output',
      })

      -- Test run_new_session command
      test_args = { args = 'test prompt new' }
      stored_fns['OpencodeRunNewSession'](test_args)
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt new', {
        new_session = true,
        focus = 'output',
      })
    end)
  end)

  describe('Lua API', function()
    it('provides callable functions that match commands', function()
      -- All core/ui methods are stubbed in before_each; no need for local spies or wrappers

      -- Test the exported functions
      assert.is_function(api.open_input, 'Should export open_input')
      api.open_input()
      assert.stub(core.open).was_called()
      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input' })

      -- Test run function
      assert.is_function(api.run, 'Should export run')
      api.run('test prompt')
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt', {
        new_session = false,
        focus = 'output',
      })

      -- Test run_new_session function
      assert.is_function(api.run_new_session, 'Should export run_new_session')
      api.run_new_session('test prompt new')
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt new', {
        new_session = true,
        focus = 'output',
      })
    end)
  end)
end)
