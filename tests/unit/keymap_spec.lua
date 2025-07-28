-- tests/unit/keymap_spec.lua
-- Tests for the keymap module

local keymap = require('opencode.keymap')

describe('opencode.keymap', function()
  -- Keep track of set keymaps to verify
  local set_keymaps = {}

  -- Track vim.cmd calls
  local cmd_calls = {}

  -- Mock vim.keymap.set and vim.cmd for testing
  local original_keymap_set
  local original_vim_cmd

  before_each(function()
    set_keymaps = {}
    cmd_calls = {}
    original_keymap_set = vim.keymap.set
    original_vim_cmd = vim.cmd

    -- Mock the functions to capture calls
    vim.keymap.set = function(modes, key, callback, opts)
      table.insert(set_keymaps, {
        modes = modes,
        key = key,
        callback = callback,
        opts = opts,
      })
    end

    vim.cmd = function(command)
      table.insert(cmd_calls, command)
    end
  end)

  after_each(function()
    -- Restore original functions
    vim.keymap.set = original_keymap_set
    vim.cmd = original_vim_cmd
  end)

  describe('setup', function()
    it('sets up keymap with the configured keys', function()
      local test_keymap = {
        global = {
          open_input = '<leader>test',
          open_input_new_session = '<leader>testNew',
          open_output = '<leader>out',
          close = '<leader>close',
          select_session = '<leader>select',
          toggle = '<leader>toggle',
          toggle_focus = '<leader>focus',
        },
      }

      keymap.setup(test_keymap)

      -- Verify that all keymaps were set up correctly
      assert.equal(#set_keymaps, 7) -- Should have 8 keymaps for our test config

      -- Create a map to find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check that all our expected keymaps were set up
      for action, key in pairs(test_keymap.global) do
        local km = keymaps_by_key[key]
        assert.is_not_nil(km, 'Keymap for key ' .. key .. ' not found')
        assert.same({ 'n', 'v' }, km.modes, 'Modes for ' .. key .. ' should be n and v')
        assert.is_function(km.callback, 'Callback for ' .. key .. ' should be a function')
        assert.is_table(km.opts, 'Options for ' .. key .. ' should be a table')
      end
    end)

    it('sets up callbacks that execute the correct commands', function()
      -- Mock API functions to track calls
      local original_api_functions = {}
      local api_calls_by_function = {}
      local api = require('opencode.api')

      -- Save original functions
      for k, v in pairs(api) do
        if type(v) == 'function' then
          original_api_functions[k] = v
          api[k] = function()
            api_calls_by_function[k] = (api_calls_by_function[k] or 0) + 1
          end
        end
      end

      -- Setup the keymap with test mappings
      local test_mappings = {
        global = {
          open_input = '<leader>test',
          open_input_new_session = '<leader>testNew',
          open_output = '<leader>out',
          close = '<leader>close',
          select_session = '<leader>select',
          toggle = '<leader>toggle',
          toggle_focus = '<leader>focus',
        },
      }

      keymap.setup(test_mappings)

      -- Create a map of key bindings to their corresponding keymaps
      local mapping_to_keymap = {}
      for _, keymap_entry in ipairs(set_keymaps) do
        mapping_to_keymap[keymap_entry.key] = keymap_entry
      end

      -- Test each callback individually
      for func_name, key_binding in pairs(test_mappings.global) do
        local keymap_entry = mapping_to_keymap[key_binding]
        assert.is_not_nil(keymap_entry, 'Keymap for ' .. func_name .. ' not found')

        -- Call the callback and check if the corresponding API function was called
        keymap_entry.callback()
        assert.equal(
          1,
          api_calls_by_function[func_name] or 0,
          'API function ' .. func_name .. ' was not called by its callback'
        )
      end

      -- Restore original API functions
      for k, v in pairs(original_api_functions) do
        api[k] = v
      end
    end)
  end)
end)
