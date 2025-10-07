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
        assert.same({ 'n', 'v' }, km.modes, 'Agents for ' .. key .. ' should be n and v')
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

  describe('buf_keymap', function()
    it('does not set keymaps when lhs is false', function()
      local bufnr = vim.api.nvim_create_buf(false, true)

      -- Should not set any keymap
      keymap.buf_keymap(false, function() end, bufnr, 'n')
      assert.equal(0, #set_keymaps, 'No keymaps should be set when lhs is false')

      -- Should set keymap
      keymap.buf_keymap('<leader>test', function() end, bufnr, 'n')
      assert.equal(1, #set_keymaps, 'Keymap should be set when lhs is valid')
      assert.equal('<leader>test', set_keymaps[1].key, 'Keymap key should match provided lhs')

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('parse_window_keymap', function()
    it('parses string values with default modes', function()
      local key, mode = keymap.parse_window_keymap('<cr>', 'submit')
      assert.equal('<cr>', key)
      assert.equal('n', mode) -- submit defaults to 'n'
    end)

    it('parses string values with correct default modes for different keymaps', function()
      local key, mode = keymap.parse_window_keymap('@', 'mention')
      assert.equal('@', key)
      assert.equal('i', mode) -- mention defaults to 'i'

      key, mode = keymap.parse_window_keymap('<up>', 'prev_prompt_history')
      assert.equal('<up>', key)
      assert.same({'n', 'i'}, mode) -- prev_prompt_history defaults to {'n', 'i'}
    end)

    it('parses table values with explicit modes', function()
      local keymap_value = { key = '<cr>', mode = 'i' }
      local key, mode = keymap.parse_window_keymap(keymap_value, 'submit')
      assert.equal('<cr>', key)
      assert.equal('i', mode)
    end)

    it('parses table values with multiple modes', function()
      local keymap_value = { key = '<tab>', mode = {'n', 'i', 'v'} }
      local key, mode = keymap.parse_window_keymap(keymap_value, 'toggle_pane')
      assert.equal('<tab>', key)
      assert.same({'n', 'i', 'v'}, mode)
    end)

    it('throws error for invalid keymap values', function()
      assert.has_error(function()
        keymap.parse_window_keymap(123, 'submit')
      end)

      assert.has_error(function()
        keymap.parse_window_keymap({}, 'submit') -- missing key field
      end)
    end)

    it('uses default mode for unknown keymap names', function()
      local key, mode = keymap.parse_window_keymap('<test>', 'unknown_keymap')
      assert.equal('<test>', key)
      assert.equal('n', mode) -- defaults to 'n' for unknown keymaps
    end)

    it('parses positional format with explicit mode', function()
      local keymap_value = { '<cr>', 'i' }
      local key, mode = keymap.parse_window_keymap(keymap_value, 'submit')
      assert.equal('<cr>', key)
      assert.equal('i', mode)
    end)

    it('parses positional format with default mode when second element missing', function()
      local keymap_value = { '<tab>' }
      local key, mode = keymap.parse_window_keymap(keymap_value, 'toggle_pane')
      assert.equal('<tab>', key)
      assert.same({'n', 'i'}, mode) -- toggle_pane defaults to {'n', 'i'}
    end)

    it('parses positional format with multiple modes', function()
      local keymap_value = { '<esc>', {'n', 'i', 'v'} }
      local key, mode = keymap.parse_window_keymap(keymap_value, 'close')
      assert.equal('<esc>', key)
      assert.same({'n', 'i', 'v'}, mode)
    end)
  end)

  describe('parse_global_keymap', function()
    it('parses string values with default modes', function()
      local key, mode = keymap.parse_global_keymap('<leader>o', 'open_input')
      assert.equal('<leader>o', key)
      assert.same({'n', 'v'}, mode) -- global keymaps default to {'n', 'v'}
    end)

    it('parses table values with explicit modes', function()
      local keymap_value = { key = '<leader>t', mode = 'n' }
      local key, mode = keymap.parse_global_keymap(keymap_value, 'toggle')
      assert.equal('<leader>t', key)
      assert.equal('n', mode)
    end)

    it('parses table values with multiple modes', function()
      local keymap_value = { key = '<leader>c', mode = {'n', 'i', 'v'} }
      local key, mode = keymap.parse_global_keymap(keymap_value, 'close')
      assert.equal('<leader>c', key)
      assert.same({'n', 'i', 'v'}, mode)
    end)

    it('throws error for invalid keymap values', function()
      assert.has_error(function()
        keymap.parse_global_keymap(123, 'toggle')  
      end)

      assert.has_error(function()
        keymap.parse_global_keymap({}, 'toggle') -- missing key field
      end)
    end)

    it('uses default mode for all global keymap names', function()
      local key, mode = keymap.parse_global_keymap('<leader>test', 'any_global_keymap')
      assert.equal('<leader>test', key)
      assert.same({'n', 'v'}, mode) -- all global keymaps default to {'n', 'v'}
    end)

    it('parses positional format with explicit mode', function()
      local keymap_value = { '<leader>t', 'n' }
      local key, mode = keymap.parse_global_keymap(keymap_value, 'toggle')
      assert.equal('<leader>t', key)
      assert.equal('n', mode)
    end)

    it('parses positional format with default mode when second element missing', function()
      local keymap_value = { '<leader>o' }
      local key, mode = keymap.parse_global_keymap(keymap_value, 'open_input')
      assert.equal('<leader>o', key)
      assert.same({'n', 'v'}, mode) -- global keymaps default to {'n', 'v'}
    end)

    it('parses positional format with multiple modes', function()
      local keymap_value = { '<leader>c', {'n', 'i', 'v'} }
      local key, mode = keymap.parse_global_keymap(keymap_value, 'close')
      assert.equal('<leader>c', key)
      assert.same({'n', 'i', 'v'}, mode)
    end)
  end)

  describe('global keymap setup with enhanced format', function()
    it('sets up global keymaps with table format and custom modes', function()
      local test_keymap = {
        global = {
          toggle = { key = '<leader>t', mode = 'n' },
          open_input = '<leader>o', -- string format, should use default modes
          close = { key = '<leader>c', mode = {'n', 'i'} },
        },
      }

      keymap.setup(test_keymap)

      assert.equal(3, #set_keymaps)

      -- Find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check toggle keymap with custom mode
      local toggle_km = keymaps_by_key['<leader>t']
      assert.is_not_nil(toggle_km)
      assert.equal('n', toggle_km.modes)

      -- Check open_input keymap with default modes
      local open_input_km = keymaps_by_key['<leader>o']
      assert.is_not_nil(open_input_km)
      assert.same({'n', 'v'}, open_input_km.modes)

      -- Check close keymap with custom multiple modes
      local close_km = keymaps_by_key['<leader>c']
      assert.is_not_nil(close_km)
      assert.same({'n', 'i'}, close_km.modes)
    end)

    it('sets up global keymaps with positional format', function()
      local test_keymap = {
        global = {
          toggle = { '<leader>t', 'n' }, -- positional format with explicit mode
          open_input = { '<leader>o' }, -- positional format with default mode
          close = { '<leader>c', {'n', 'i', 'v'} }, -- positional format with multiple modes
        },
      }

      keymap.setup(test_keymap)

      assert.equal(3, #set_keymaps)

      -- Find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check toggle keymap with explicit mode
      local toggle_km = keymaps_by_key['<leader>t']
      assert.is_not_nil(toggle_km)
      assert.equal('n', toggle_km.modes)

      -- Check open_input keymap with default modes
      local open_input_km = keymaps_by_key['<leader>o']
      assert.is_not_nil(open_input_km)
      assert.same({'n', 'v'}, open_input_km.modes)

      -- Check close keymap with multiple modes
      local close_km = keymaps_by_key['<leader>c']
      assert.is_not_nil(close_km)
      assert.same({'n', 'i', 'v'}, close_km.modes)
    end)
  end)
end)
