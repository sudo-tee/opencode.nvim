local api = require('opencode.api')
local core = require('opencode.core')
local ui = require('opencode.ui.ui')
local state = require('opencode.state')
local stub = require('luassert.stub')
local assert = require('luassert')

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
    stub(core, 'cancel')
    stub(core, 'send_message')
    stub(ui, 'close_windows')
  end)

  after_each(function()
    -- luassert.stub automatically restores originals after each test
  end)

  describe('commands table', function()
    it('contains the expected commands with proper structure', function()
      local expected_commands = {
        'open',
        'close',
        'cancel',
        'toggle',
        'toggle_focus',
        'toggle_pane',
        'session',
        'swap',
        'undo',
        'redo',
        'diff',
        'revert',
        'restore',
        'breakpoint',
        'agent',
        'models',
        'run',
        'run_new',
        'help',
        'mcp',
        'permission',
      }

      for _, cmd_name in ipairs(expected_commands) do
        local cmd = api.commands[cmd_name]
        assert.truthy(cmd, 'Command ' .. cmd_name .. ' should exist')
        assert.truthy(cmd.desc, 'Command should have a description')
        assert.is_function(cmd.fn, 'Command should have a function')
      end
    end)
  end)

  describe('setup', function()
    it('registers the main Opencode command and legacy commands', function()
      api.setup()

      local main_cmd_found = false
      local legacy_cmd_count = 0

      for i, cmd in ipairs(created_commands) do
        if cmd.name == 'Opencode' then
          main_cmd_found = true
          assert.equal('Opencode.nvim main command with nested subcommands', cmd.opts.desc)
        else
          legacy_cmd_count = legacy_cmd_count + 1
          assert.truthy(string.match(cmd.opts.desc, 'deprecated'), 'Legacy command should be marked as deprecated')
        end
      end

      assert.truthy(main_cmd_found, 'Main Opencode command should be registered')
      assert.truthy(legacy_cmd_count > 0, 'Legacy commands should be registered')
    end)

    it('sets up legacy command functions that route to main command', function()
      local stored_fns = {}
      local cmd_stub

      vim.api.nvim_create_user_command = function(name, fn, _)
        stored_fns[name] = fn
      end

      cmd_stub = stub(vim, 'cmd')

      api.setup()

      stored_fns['OpencodeOpenInput']()
      assert.stub(cmd_stub).was_called()
      assert.stub(cmd_stub).was_called_with('Opencode open input')

      cmd_stub:clear()
      stored_fns['OpencodeStop']()
      assert.stub(cmd_stub).was_called_with('Opencode cancel')

      cmd_stub:clear()
      stored_fns['OpencodeClose']()
      assert.stub(cmd_stub).was_called_with('Opencode close')

      cmd_stub:revert()
    end)
  end)

  describe('Lua API', function()
    it('provides callable functions that match commands', function()
      -- All core/ui methods are stubbed in before_each; no need for local spies or wrappers

      -- Test the exported functions
      assert.is_function(api.open_input, 'Should export open_input')
      api.open_input()
      assert.stub(core.open).was_called()
      assert.stub(core.open).was_called_with({ new_session = false, focus = 'input', start_insert = true })

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
