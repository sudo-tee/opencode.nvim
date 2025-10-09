-- tests/unit/keymap_spec.lua
-- Tests for the keymap module

local keymap = require('opencode.keymap')
local assert = require('luassert')

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
    it('sets up keymap with new format configured keys', function()
      local test_keymap = {
        editor = {
          ['<leader>test'] = { 'open_input' },
          ['<leader>testNew'] = { 'open_input_new_session' },
          ['<leader>out'] = { 'open_output' },
          ['<leader>close'] = { 'close' },
          ['<leader>select'] = { 'select_session' },
          ['<leader>toggle'] = { 'toggle' },
          ['<leader>focus'] = { 'toggle_focus' },
        },
      }

      keymap.setup(test_keymap)

      -- Verify that all keymaps were set up correctly
      assert.equal(#set_keymaps, 7) -- Should have 7 keymaps for our test config

      -- Create a map to find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check that all our expected keymaps were set up
      for key, config_entry in pairs(test_keymap.editor) do
        local km = keymaps_by_key[key]
        assert.is_not_nil(km, 'Keymap for key ' .. key .. ' not found')
        assert.same({ 'n', 'v' }, km.modes, 'Modes for ' .. key .. ' should be n and v')
        assert.is_function(km.callback, 'Callback for ' .. key .. ' should be a function')
        assert.is_table(km.opts, 'Options for ' .. key .. ' should be a table')
      end
    end)

    it('sets up keymap with old format configured keys (normalized)', function()
      local config = require('opencode.config')

      -- Old format keymap config
      local old_format_keymap = {
        open_input = '<leader>test_old',
        open_input_new_session = '<leader>testNewOld',
        open_output = '<leader>outOld',
        close = '<leader>closeOld',
        select_session = '<leader>selectOld',
        toggle = '<leader>toggleOld',
        toggle_focus = '<leader>focusOld',
      }

      -- Normalize old format to new format (normally config.setup would do this)
      local normalized_keymap = config.normalize_keymap(old_format_keymap)

      local test_keymap = {
        editor = normalized_keymap,
      }

      keymap.setup(test_keymap)

      -- Verify that all keymaps were set up correctly
      assert.equal(#set_keymaps, 7) -- Should have 7 keymaps for our test config

      -- Create a map to find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check that all our expected keymaps were set up (verify old format was normalized)
      for func_name, key_binding in pairs(old_format_keymap) do
        local km = keymaps_by_key[key_binding]
        assert.is_not_nil(km, 'Keymap for key ' .. key_binding .. ' not found')
        assert.same({ 'n', 'v' }, km.modes, 'Modes for ' .. key_binding .. ' should be n and v')
        assert.is_function(km.callback, 'Callback for ' .. key_binding .. ' should be a function')
        assert.is_table(km.opts, 'Options for ' .. key_binding .. ' should be a table')
      end
    end)

    it('sets up callbacks that execute the correct commands (new format)', function()
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

      -- Setup the keymap with test mappings (new format)
      local test_mappings = {
        editor = {
          ['<leader>test'] = { 'open_input' },
          ['<leader>testNew'] = { 'open_input_new_session' },
          ['<leader>out'] = { 'open_output' },
          ['<leader>close'] = { 'close' },
          ['<leader>select'] = { 'select_session' },
          ['<leader>toggle'] = { 'toggle' },
          ['<leader>focus'] = { 'toggle_focus' },
        },
      }

      keymap.setup(test_mappings)

      -- Create a map of key bindings to their corresponding keymaps
      local mapping_to_keymap = {}
      for _, keymap_entry in ipairs(set_keymaps) do
        mapping_to_keymap[keymap_entry.key] = keymap_entry
      end

      -- Test each callback individually
      for key_binding, config_entry in pairs(test_mappings.editor) do
        local func_name = config_entry[1] -- Extract function name from table format
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

    it('sets up callbacks that execute the correct commands (old format normalized)', function()
      -- Mock API functions to track calls
      local original_api_functions = {}
      local api_calls_by_function = {}
      local api = require('opencode.api')
      local config = require('opencode.config')

      -- Save original functions
      for k, v in pairs(api) do
        if type(v) == 'function' then
          original_api_functions[k] = v
          api[k] = function()
            api_calls_by_function[k] = (api_calls_by_function[k] or 0) + 1
          end
        end
      end

      -- Old format keymap config
      local old_format_mappings = {
        open_input = '<leader>test_old_cb',
        open_input_new_session = '<leader>testNewOld_cb',
        open_output = '<leader>outOld_cb',
        close = '<leader>closeOld_cb',
        select_session = '<leader>selectOld_cb',
        toggle = '<leader>toggleOld_cb',
        toggle_focus = '<leader>focusOld_cb',
      }

      -- Normalize and setup
      local normalized_mappings = config.normalize_keymap(old_format_mappings)
      local test_mappings = {
        editor = normalized_mappings,
      }

      keymap.setup(test_mappings)

      -- Create a map of key bindings to their corresponding keymaps
      local mapping_to_keymap = {}
      for _, keymap_entry in ipairs(set_keymaps) do
        mapping_to_keymap[keymap_entry.key] = keymap_entry
      end

      -- Test each callback individually (using original old format mapping)
      for func_name, key_binding in pairs(old_format_mappings) do
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

  describe('normalize_keymap', function()
    it('normalizes old format keymap to new format correctly', function()
      local config = require('opencode.config')

      local old_format = {
        open_input = '<leader>oi',
        close = '<leader>oq',
        toggle = '<leader>og',
        select_session = '<leader>os',
      }

      local normalized = config.normalize_keymap(old_format)

      -- Verify the structure was correctly transformed
      assert.is_table(normalized, 'Normalized keymap should be a table')

      -- Check each mapping was transformed correctly
      assert.same({ 'open_input' }, normalized['<leader>oi'], 'open_input mapping should be normalized to table format')
      assert.same({ 'close' }, normalized['<leader>oq'], 'close mapping should be normalized to table format')
      assert.same({ 'toggle' }, normalized['<leader>og'], 'toggle mapping should be normalized to table format')

      assert.same(
        { 'select_session' },
        normalized['<leader>os'],
        'select_session mapping should be normalized to table format'
      )

      -- Verify the old keys are no longer present (they should be used as new keys)
      assert.is_nil(normalized.open_input, 'Old format key should not exist in normalized config')
      assert.is_nil(normalized.close, 'Old format key should not exist in normalized config')
      assert.is_nil(normalized.toggle, 'Old format key should not exist in normalized config')
      assert.is_nil(normalized.select_session, 'Old format key should not exist in normalized config')
    end)

    it('shows error message for unknown API functions', function()
      local notify_calls = {}
      local original_notify = vim.notify

      -- Mock vim.notify to capture error messages
      vim.notify = function(message, level)
        table.insert(notify_calls, { message = message, level = level })
      end

      local test_keymap = {
        editor = {
          ['<leader>invalid'] = { 'nonexistent_api_function' },
        },
      }

      keymap.setup(test_keymap)

      -- Should have one error notification
      assert.equal(1, #notify_calls, 'Should have one error notification')
      assert.equal(vim.log.levels.WARN, notify_calls[1].level, 'Should be an error level notification')
      assert.match(
        'No action found for keymap: <leader>invalid %-> nonexistent_api_function',
        notify_calls[1].message,
        'Should mention the missing keymap action'
      )

      -- Should not have set up any keymap for the invalid function
      assert.equal(0, #set_keymaps, 'No keymaps should be set for invalid API functions')

      -- Restore original notify
      vim.notify = original_notify
    end)

    it('uses custom description from config_entry', function()
      local test_keymap = {
        editor = {
          ['<leader>test'] = { 'open_input', desc = 'Custom description for open input' },
          ['<leader>func'] = { function() end, desc = 'Custom function description' },
        },
      }

      keymap.setup(test_keymap)

      assert.equal(2, #set_keymaps, 'Should set up 2 keymaps')

      -- Find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check API function keymap uses custom description
      local api_keymap = keymaps_by_key['<leader>test']
      assert.is_not_nil(api_keymap, 'API keymap should exist')
      assert.equal(
        'Custom description for open input',
        api_keymap.opts.desc,
        'Should use custom description for API function'
      )

      -- Check custom function keymap uses custom description
      local func_keymap = keymaps_by_key['<leader>func']
      assert.is_not_nil(func_keymap, 'Function keymap should exist')
      assert.equal('Custom function description', func_keymap.opts.desc, 'Should use custom description for function')
    end)

    it('falls back to API description when no custom desc provided', function()
      local test_keymap = {
        editor = {
          ['<leader>test'] = { 'open_input' }, -- No custom desc
        },
      }

      keymap.setup(test_keymap)

      assert.equal(1, #set_keymaps, 'Should set up 1 keymap')

      -- The API description should be used (assuming open_input has a description in the API)
      local keymap_entry = set_keymaps[1]
      assert.is_not_nil(keymap_entry.opts.desc, 'Should have a description from API fallback')
    end)
  end)

  describe('setup_window_keymaps', function()
    it('handles unknown API functions with error message', function()
      local notify_calls = {}
      local original_notify = vim.notify

      -- Mock vim.notify to capture error messages
      vim.notify = function(message, level)
        table.insert(notify_calls, { message = message, level = level })
      end

      local bufnr = vim.api.nvim_create_buf(false, true)
      local window_keymap_config = {
        ['<cr>'] = { 'nonexistent_window_function' },
      }

      keymap.setup_window_keymaps(window_keymap_config, bufnr)

      -- Should have one error notification
      assert.equal(1, #notify_calls, 'Should have one error notification')
      assert.equal(vim.log.levels.WARN, notify_calls[1].level, 'Should be an error level notification')
      assert.match(
        'No action found for keymap: <cr> %-> nonexistent_window_function',
        notify_calls[1].message,
        'Should mention the missing keymap action'
      )

      -- Should not have set up any keymap for the invalid function
      assert.equal(0, #set_keymaps, 'No keymaps should be set for invalid API functions')

      -- Cleanup
      vim.notify = original_notify
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('uses custom description for window keymaps', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      local window_keymap_config = {
        ['<cr>'] = { 'submit_input_prompt', desc = 'Custom submit description' },
        ['<c-c>'] = { function() end, desc = 'Custom function description' },
      }

      keymap.setup_window_keymaps(window_keymap_config, bufnr)

      assert.equal(2, #set_keymaps, 'Should set up 2 window keymaps')

      -- Find keymaps by key
      local keymaps_by_key = {}
      for _, km in ipairs(set_keymaps) do
        keymaps_by_key[km.key] = km
      end

      -- Check API function keymap uses custom description
      local api_keymap = keymaps_by_key['<cr>']
      assert.is_not_nil(api_keymap, 'API keymap should exist')
      assert.equal('Custom submit description', api_keymap.opts.desc, 'Should use custom description for API function')

      -- Check custom function keymap uses custom description
      local func_keymap = keymaps_by_key['<c-c>']
      assert.is_not_nil(func_keymap, 'Function keymap should exist')
      assert.equal('Custom function description', func_keymap.opts.desc, 'Should use custom description for function')

      -- Cleanup
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)



  describe('setup_permisson_keymap', function()
    it('sets up permission keymaps when there is a current permission', function()
      local state = require('opencode.state')
      state.current_permission = { id = 'test' }

      local bufnr = vim.api.nvim_create_buf(false, true)
      local config = require('opencode.config')
      local original_get = config.get
      config.get = function()
        return {
          keymap = {
            permission = {
              accept = 'a',
              accept_all = 'A',
              deny = 'd',
            },
          },
        }
      end

      keymap.toggle_permission_keymap(bufnr)

      assert.equal(3, #set_keymaps, 'Three permission keymaps should be set')

      local keys_set = {}
      for _, km in ipairs(set_keymaps) do
        table.insert(keys_set, km.key)
        assert.same({ 'n', 'i' }, km.modes, 'Permission keymaps should be set for n and i modes')
        assert.is_function(km.callback, 'Permission keymap callback should be a function')
      end

      assert.is_true(vim.tbl_contains(keys_set, 'a'), 'Accept keymap should be set')
      assert.is_true(vim.tbl_contains(keys_set, 'A'), 'Accept All keymap should be set')
      assert.is_true(vim.tbl_contains(keys_set, 'd'), 'Deny keymap should be set')

      config.get = original_get
      vim.api.nvim_buf_delete(bufnr, { force = true })
      state.current_permission = nil
    end)

    it('should delete existing permission keymaps if no current permission exists after being set', function()
      local state = require('opencode.state')
      state.current_permission = { id = 'test' } --

      local bufnr = vim.api.nvim_create_buf(false, true)
      local config = require('opencode.config')
      local original_get = config.get
      config.get = function()
        return {
          keymap = {
            permission = {
              accept = 'a',
              accept_all = 'A',
              deny = 'd',
            },
          },
        }
      end

      keymap.toggle_permission_keymap(bufnr)
      assert.equal(3, #set_keymaps, 'Three permission keymaps should be set')

      set_keymaps = {}
      state.current_permission = nil
      keymap.toggle_permission_keymap(bufnr)
      assert.equal(0, #set_keymaps, 'Permission keymaps should be cleared when there is no current permission')

      config.get = original_get
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('does not set permission keymaps when there is no current permission', function()
      local state = require('opencode.state')
      state.current_permission = nil -- Ensure no current permission

      local bufnr = vim.api.nvim_create_buf(false, true)
      local config = require('opencode.config')
      local original_get = config.get
      config.get = function()
        return {
          keymap = {
            permission = {
              accept = 'a',
              accept_all = 'A',
              deny = 'd',
            },
          },
        }
      end

      keymap.toggle_permission_keymap(bufnr)

      assert.equal(0, #set_keymaps, 'No permission keymaps should be set when there is no current permission')

      -- Cleanup
      config.get = original_get
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)
end)
