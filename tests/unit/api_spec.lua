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

  describe('run command argument parsing', function()
    it('parses agent prefix and passes to send_message', function()
      api.commands.run.fn({ 'agent=plan', 'analyze', 'this', 'code' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('analyze this code', {
        new_session = false,
        focus = 'output',
        agent = 'plan',
      })
    end)

    it('parses model prefix and passes to send_message', function()
      api.commands.run.fn({ 'model=openai/gpt-4', 'test', 'prompt' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt', {
        new_session = false,
        focus = 'output',
        model = 'openai/gpt-4',
      })
    end)

    it('parses context prefix and passes to send_message', function()
      api.commands.run.fn({ 'context=current_file.enabled=false', 'test' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test', {
        new_session = false,
        focus = 'output',
        context = { current_file = { enabled = false } },
      })
    end)

    it('parses multiple prefixes and passes all to send_message', function()
      api.commands.run.fn({ 'agent=plan', 'model=openai/gpt-4', 'context=current_file.enabled=false', 'analyze', 'code' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('analyze code', {
        new_session = false,
        focus = 'output',
        agent = 'plan',
        model = 'openai/gpt-4',
        context = { current_file = { enabled = false } },
      })
    end)

    it('works with run_new command', function()
      api.commands.run_new.fn({ 'agent=plan', 'model=openai/gpt-4', 'new', 'session', 'prompt' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('new session prompt', {
        new_session = true,
        focus = 'output',
        agent = 'plan',
        model = 'openai/gpt-4',
      })
    end)

    it('requires a prompt after prefixes', function()
      local notify_stub = stub(vim, 'notify')
      api.commands.run.fn({ 'agent=plan' })
      assert.stub(notify_stub).was_called_with('Prompt required', vim.log.levels.ERROR)
      notify_stub:revert()
    end)

    it('Lua API accepts opts directly without parsing', function()
      api.run('test prompt', { agent = 'plan', model = 'openai/gpt-4' })
      assert.stub(core.send_message).was_called()
      assert.stub(core.send_message).was_called_with('test prompt', {
        new_session = false,
        focus = 'output',
        agent = 'plan',
        model = 'openai/gpt-4',
      })
    end)
  end)

  describe('/mcp command', function()
    it('displays MCP server configuration when available', function()
      local config_file = require('opencode.config_file')
      local original_get_mcp_servers = config_file.get_mcp_servers

      config_file.get_mcp_servers = function()
        return {
          filesystem = {
            type = 'local',
            enabled = true,
            command = { 'npx', '-y', '@modelcontextprotocol/server-filesystem' },
          },
          github = {
            type = 'remote',
            enabled = false,
            url = 'https://example.com/mcp',
          },
        }
      end

      stub(ui, 'render_lines')
      stub(api, 'open_input')

      api.mcp()

      assert.stub(api.open_input).was_called()
      assert.stub(ui.render_lines).was_called()

      local render_args = ui.render_lines.calls[1].refs[1]
      local rendered_text = table.concat(render_args, '\n')

      assert.truthy(rendered_text:match('Available MCP servers'))
      assert.truthy(rendered_text:match('filesystem'))
      assert.truthy(rendered_text:match('github'))
      assert.truthy(rendered_text:match('local'))
      assert.truthy(rendered_text:match('remote'))

      config_file.get_mcp_servers = original_get_mcp_servers
    end)

    it('shows warning when no MCP configuration exists', function()
      local config_file = require('opencode.config_file')
      local original_get_mcp_servers = config_file.get_mcp_servers

      config_file.get_mcp_servers = function()
        return nil
      end

      local notify_stub = stub(vim, 'notify')

      api.mcp()

      assert.stub(notify_stub).was_called_with(
        'No MCP configuration found. Please check your opencode config file.',
        vim.log.levels.WARN
      )

      config_file.get_mcp_servers = original_get_mcp_servers
      notify_stub:revert()
    end)
  end)

  describe('/commands command', function()
    it('displays user commands when available', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        return {
          ['build'] = { description = 'Build the project' },
          ['test'] = { description = 'Run tests' },
          ['deploy'] = { description = 'Deploy to production' },
        }
      end

      stub(ui, 'render_lines')
      stub(api, 'open_input')

      api.commands_list()

      assert.stub(api.open_input).was_called()
      assert.stub(ui.render_lines).was_called()

      local render_args = ui.render_lines.calls[1].refs[1]
      local rendered_text = table.concat(render_args, '\n')

      assert.truthy(rendered_text:match('Available User Commands'))
      assert.truthy(rendered_text:match('Description'))
      assert.truthy(rendered_text:match('build'))
      assert.truthy(rendered_text:match('Build the project'))
      assert.truthy(rendered_text:match('test'))
      assert.truthy(rendered_text:match('Run tests'))
      assert.truthy(rendered_text:match('deploy'))
      assert.truthy(rendered_text:match('Deploy to production'))

      config_file.get_user_commands = original_get_user_commands
    end)

    it('shows warning when no user commands exist', function()
      local config_file = require('opencode.config_file')
      local original_get_user_commands = config_file.get_user_commands

      config_file.get_user_commands = function()
        return nil
      end

      local notify_stub = stub(vim, 'notify')

      api.commands_list()

      assert.stub(notify_stub).was_called_with(
        'No user commands found. Please check your opencode config file.',
        vim.log.levels.WARN
      )

      config_file.get_user_commands = original_get_user_commands
      notify_stub:revert()
    end)
  end)
end)
