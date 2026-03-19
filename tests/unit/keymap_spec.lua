local assert = require('luassert')

describe('opencode.keymap', function()
  -- Keep track of set keymaps to verify
  local set_keymaps = {}

  -- Track vim.cmd calls
  local cmd_calls = {}

  -- Mock vim.keymap.set and vim.cmd for testing
  local original_keymap_set
  local original_vim_cmd

  -- Mock the API module to break circular dependency
  local mock_api
  local keymap

  -- Mock completion module state (controlled per test)
  local mock_completion
  local original_nvim_feedkeys
  local feedkeys_calls = {}

  before_each(function()
    set_keymaps = {}
    cmd_calls = {}
    feedkeys_calls = {}
    original_keymap_set = vim.keymap.set
    original_vim_cmd = vim.cmd
    original_nvim_feedkeys = vim.api.nvim_feedkeys

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

    vim.api.nvim_feedkeys = function(keys, mode, escape_ks)
      table.insert(feedkeys_calls, { keys = keys, mode = mode, escape_ks = escape_ks })
    end

    -- Mock the API module before requiring keymap
    mock_api = {
      open_input = function() end,
      toggle = function() end,
      submit_input_prompt = function() end,
      permission_accept = function() end,
      permission_accept_all = function() end,
      permission_deny = function() end,
      commands = {
        open_input = { desc = 'Open input window' },
        toggle = { desc = 'Toggle opencode windows' },
        submit_input_prompt = { desc = 'Submit input prompt' },
      },
    }
    package.loaded['opencode.api'] = mock_api

    -- Mock the state module
    local mock_state = {
      current_permission = nil,
    }
    package.loaded['opencode.state'] = mock_state

    -- Mock the config module
    local mock_config = {}
    package.loaded['opencode.config'] = mock_config

    -- Mock the completion module (visible = false by default)
    mock_completion = {
      is_completion_visible = function()
        return false
      end,
    }
    package.loaded['opencode.ui.completion'] = mock_completion

    -- Now require the keymap module
    keymap = require('opencode.keymap')
  end)

  after_each(function()
    -- Restore original functions
    vim.keymap.set = original_keymap_set
    vim.cmd = original_vim_cmd
    vim.api.nvim_feedkeys = original_nvim_feedkeys

    -- Clean up package loading
    package.loaded['opencode.keymap'] = nil
    package.loaded['opencode.api'] = nil
    package.loaded['opencode.state'] = nil
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.ui.completion'] = nil
  end)

  describe('normalize_keymap', function()
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
          ['<leader>test'] = { 'toggle' },
        },
      }

      keymap.setup(test_keymap)

      assert.equal(1, #set_keymaps, 'Should set up 1 keymap')

      local keymap_entry = set_keymaps[1]
      assert.is_not_nil(keymap_entry.opts.desc, 'Should have a description from API fallback')
      assert.equal('Toggle opencode windows', keymap_entry.opts.desc)
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

  describe('defer_to_completion', function()
    it('calls the callback directly when completion is not visible', function()
      local callback_called = false
      local test_keymap = {
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            defer_to_completion = true,
            desc = 'Tab with completion defer',
          },
        },
      }

      keymap.setup(test_keymap)

      assert.equal(1, #set_keymaps, 'Should register one keymap')
      local registered = set_keymaps[1]

      registered.callback()

      assert.is_true(callback_called, 'Callback should be called when completion is not visible')
      assert.equal(0, #feedkeys_calls, 'Should not feed keys when completion is not visible')
    end)

    it('feeds the key binding when completion is visible instead of calling the callback', function()
      mock_completion.is_completion_visible = function()
        return true
      end

      local callback_called = false
      local test_keymap = {
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            defer_to_completion = true,
            desc = 'Tab with completion defer',
          },
        },
      }

      keymap.setup(test_keymap)

      assert.equal(1, #set_keymaps, 'Should register one keymap')
      local registered = set_keymaps[1]

      registered.callback()

      assert.is_false(callback_called, 'Callback should NOT be called when completion is visible')
      assert.equal(1, #feedkeys_calls, 'Should feed the key binding to the completion engine')
    end)

    it('does not wrap with completion check when defer_to_completion is not set', function()
      local callback_called = false
      local test_keymap = {
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            desc = 'Tab without defer',
          },
        },
      }

      mock_completion.is_completion_visible = function()
        return true
      end

      keymap.setup(test_keymap)

      assert.equal(1, #set_keymaps, 'Should register one keymap')
      local registered = set_keymaps[1]

      registered.callback()

      assert.is_true(callback_called, 'Callback should be called directly without completion check')
      assert.equal(0, #feedkeys_calls, 'Should not feed keys when defer_to_completion is not set')
    end)
  end)
end)
