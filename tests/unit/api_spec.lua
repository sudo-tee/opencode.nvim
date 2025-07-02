local api = require("opencode.api")
local core = require("opencode.core")
local ui = require("opencode.ui.ui")
local state = require("opencode.state")

describe("opencode.api", function()
  local created_commands = {}
  local original_create_command

  before_each(function()
    created_commands = {}
    original_create_command = vim.api.nvim_create_user_command

    vim.api.nvim_create_user_command = function(name, fn, opts)
      table.insert(created_commands, {
        name = name,
        fn = fn,
        opts = opts
      })
    end

    -- Mock core functions that commands call
    core.open = function() end
    core.run = function() end
    core.stop = function() end
    ui.close_windows = function() end
  end)

  after_each(function()
    vim.api.nvim_create_user_command = original_create_command
  end)

  describe("commands table", function()
    it("contains the expected commands with proper structure", function()
      local expected_commands = {
        "open_input",
        "open_input_new_session",
        "open_output",
        "close",
        "stop",
        "run",
        "run_new_session"
      }

      for _, cmd_name in ipairs(expected_commands) do
        local cmd = api.commands[cmd_name]
        assert.truthy(cmd, "Command " .. cmd_name .. " should exist")
        assert.truthy(cmd.name, "Command should have a name")
        assert.truthy(cmd.desc, "Command should have a description")
        assert.is_function(cmd.fn, "Command should have a function")
      end
    end)
  end)

  describe("setup", function()
    it("registers all commands", function()
      api.setup()

      local expected_count = 0
      for _ in pairs(api.commands) do expected_count = expected_count + 1 end

      assert.equal(expected_count, #created_commands, "All commands should be registered")

      for i, cmd in ipairs(created_commands) do
        local found = false
        for _, def in pairs(api.commands) do
          if def.name == cmd.name then
            found = true
            assert.equal(def.desc, cmd.opts.desc, "Command should have correct description")
            break
          end
        end
        assert.truthy(found, "Command " .. cmd.name .. " should be defined in commands table")
      end
    end)

    it("sets up command functions that call the correct core functions", function()
      -- We'll use the real vim.api.nvim_create_user_command implementation to store functions
      local stored_fns = {}
      vim.api.nvim_create_user_command = function(name, fn, _)
        stored_fns[name] = fn
      end

      -- Spy on core functions
      local core_open_called = false
      local core_stop_called = false
      local core_run_called = false
      local ui_close_called = false
      local core_open_args = nil
      local core_run_args = nil
      local core_run_opts = nil

      core.open = function(args)
        core_open_called = true
        core_open_args = args
      end
      
      core.run = function(args, opts)
        core_run_called = true
        core_run_args = args
        core_run_opts = opts
      end

      core.stop = function()
        core_stop_called = true
      end

      ui.close_windows = function()
        ui_close_called = true
      end

      api.setup()

      -- Test open_input command
      stored_fns["OpencodeOpenInput"]()
      assert.truthy(core_open_called, "Should call core.open")
      assert.same({ new_session = false, focus = "input" }, core_open_args)

      -- Reset
      core_open_called = false
      core_open_args = nil

      -- Test open_input_new_session command
      stored_fns["OpencodeOpenInputNewSession"]()
      assert.truthy(core_open_called, "Should call core.open")
      assert.same({ new_session = true, focus = "input" }, core_open_args)

      -- Test stop command
      stored_fns["OpencodeStop"]()
      assert.truthy(core_stop_called, "Should call core.stop")

      -- Test close command
      stored_fns["OpencodeClose"]()
      assert.truthy(ui_close_called, "Should call ui.close_windows")
      
      -- Test run command
      local test_args = { args = "test prompt" }
      stored_fns["OpencodeRun"](test_args)
      assert.truthy(core_run_called, "Should call core.run")
      assert.equal("test prompt", core_run_args)
      assert.same({ 
        ensure_ui = true, 
        new_session = false, 
        focus = "output" 
      }, core_run_opts)
      
      -- Reset
      core_run_called = false
      core_run_args = nil
      core_run_opts = nil
      
      -- Test run_new_session command
      test_args = { args = "test prompt new" }
      stored_fns["OpencodeRunNewSession"](test_args)
      assert.truthy(core_run_called, "Should call core.run")
      assert.equal("test prompt new", core_run_args)
      assert.same({ 
        ensure_ui = true, 
        new_session = true, 
        focus = "output" 
      }, core_run_opts)
    end)
  end)

  describe("Lua API", function()
    it("provides callable functions that match commands", function()
      -- Mock core functions
      local core_open_called = false
      local core_run_called = false
      local core_stop_called = false
      local ui_close_called = false
      local core_open_args = nil
      local core_run_args = nil
      local core_run_opts = nil

      core.open = function(args)
        core_open_called = true
        core_open_args = args
      end
      
      core.run = function(args, opts)
        core_run_called = true
        core_run_args = args
        core_run_opts = opts
      end

      core.stop = function()
        core_stop_called = true
      end

      ui.close_windows = function()
        ui_close_called = true
      end
      
      -- Test the exported functions
      assert.is_function(api.open_input, "Should export open_input")
      api.open_input()
      assert.truthy(core_open_called, "Should call core.open")
      assert.same({ new_session = false, focus = "input" }, core_open_args)
      
      -- Reset
      core_open_called = false
      core_open_args = nil
      
      -- Test run function
      assert.is_function(api.run, "Should export run")
      api.run("test prompt")
      assert.truthy(core_run_called, "Should call core.run")
      assert.equal("test prompt", core_run_args)
      assert.same({ 
        ensure_ui = true, 
        new_session = false, 
        focus = "output" 
      }, core_run_opts)
      
      -- Reset
      core_run_called = false
      core_run_args = nil
      core_run_opts = nil
      
      -- Test run_new_session function
      assert.is_function(api.run_new_session, "Should export run_new_session")
      api.run_new_session("test prompt new")
      assert.truthy(core_run_called, "Should call core.run")
      assert.equal("test prompt new", core_run_args)
      assert.same({ 
        ensure_ui = true, 
        new_session = true, 
        focus = "output" 
      }, core_run_opts)
    end)
  end)
end)
