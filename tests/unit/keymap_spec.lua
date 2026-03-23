local assert = require('luassert')

describe('opencode.keymap', function()
  local set_keymaps = {}
  local cmd_calls = {}
  local original_keymap_set
  local original_vim_cmd
  local original_notify
  local original_nvim_feedkeys

  local mock_api
  local mock_commands
  local mock_completion
  local keymap
  local routed_opts
  local toggle_calls
  local notify_calls
  local feedkeys_calls = {}

  before_each(function()
    set_keymaps = {}
    cmd_calls = {}
    routed_opts = {}
    toggle_calls = 0
    notify_calls = {}
    feedkeys_calls = {}

    original_keymap_set = vim.keymap.set
    original_vim_cmd = vim.cmd
    original_notify = vim.notify
    original_nvim_feedkeys = vim.api.nvim_feedkeys

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

    mock_api = {
      open_input = function() end,
      toggle = function()
        toggle_calls = toggle_calls + 1
      end,
    }

    mock_commands = {
      get_commands = function()
        return {
          open_input = { desc = 'Open input window', execute = function() end },
          toggle = { desc = 'Toggle opencode windows', execute = function() end },
          submit_input_prompt = { desc = 'Submit input prompt', execute = function() end },
        }
      end,
      execute_command_opts = function(opts)
        table.insert(routed_opts, vim.deepcopy(opts))
      end,
    }

    mock_completion = {
      is_completion_visible = function()
        return false
      end,
    }

    package.loaded['opencode.api'] = mock_api
    package.loaded['opencode.commands'] = mock_commands
    package.loaded['opencode.ui.completion'] = mock_completion
    package.loaded['opencode.state'] = {}
    package.loaded['opencode.config'] = {}

    vim.notify = function(message, level)
      table.insert(notify_calls, { message = message, level = level })
    end

    keymap = require('opencode.keymap')
  end)

  after_each(function()
    vim.keymap.set = original_keymap_set
    vim.cmd = original_vim_cmd
    vim.notify = original_notify
    vim.api.nvim_feedkeys = original_nvim_feedkeys

    package.loaded['opencode.keymap'] = nil
    package.loaded['opencode.api'] = nil
    package.loaded['opencode.commands'] = nil
    package.loaded['opencode.ui.completion'] = nil
    package.loaded['opencode.state'] = nil
    package.loaded['opencode.config'] = nil
  end)

  describe('normalize_keymap', function()
    it('uses custom description from config_entry', function()
      keymap.setup({
        editor = {
          ['<leader>test'] = { 'open_input', desc = 'Custom description for open input' },
          ['<leader>func'] = { function() end, desc = 'Custom function description' },
        },
      })

      assert.equal(2, #set_keymaps)
      local by_key = {}
      for _, km in ipairs(set_keymaps) do by_key[km.key] = km end

      assert.equal('Custom description for open input', by_key['<leader>test'].opts.desc)
      assert.equal('Custom function description', by_key['<leader>func'].opts.desc)
    end)

    it('falls back to command_def description when no custom desc provided', function()
      keymap.setup({ editor = { ['<leader>test'] = { 'toggle' } } })

      assert.equal(1, #set_keymaps)
      assert.equal('Toggle opencode windows', set_keymaps[1].opts.desc)
    end)

    it('falls back to empty description for function actions without desc', function()
      keymap.setup({
        editor = {
          ['<leader>fn'] = { function() end },
        },
      })

      assert.equal(1, #set_keymaps)
      assert.equal('', set_keymaps[1].opts.desc)
    end)

    it('routes command-like keymaps through execute_command_opts', function()
      keymap.setup({ editor = { ['<leader>test'] = { 'toggle' } } })

      assert.equal(1, #set_keymaps)
      set_keymaps[1].callback()

      assert.equal(1, #routed_opts)
      assert.equal('toggle', routed_opts[1].args)
      assert.equal(0, toggle_calls, 'Direct api.toggle should not be called')
    end)

    it('rejects unroutable string actions', function()
      keymap.setup({ editor = { ['<leader>adhoc'] = { 'ad_hoc_action' } } })

      assert.equal(0, #set_keymaps)
      assert.equal(1, #notify_calls)
      assert.equal(vim.log.levels.ERROR, notify_calls[1].level)
      assert.matches('Cannot find keymap action: ad_hoc_action', notify_calls[1].message)
    end)
  end)

  describe('setup_window_keymaps', function()
    it('routes input-window string actions through execute_command_opts', function()
      local bufnr = vim.api.nvim_create_buf(false, true)
      keymap.setup_window_keymaps({ ['<cr>'] = { 'submit_input_prompt' } }, bufnr)

      assert.equal(1, #set_keymaps)
      set_keymaps[1].callback()

      assert.equal(1, #routed_opts)
      assert.equal('submit_input_prompt', routed_opts[1].args)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('defer_to_completion', function()
    it('calls the callback directly when completion is not visible', function()
      local callback_called = false
      keymap.setup({
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            defer_to_completion = true,
            desc = 'Tab with completion defer',
          },
        },
      })

      assert.equal(1, #set_keymaps)
      set_keymaps[1].callback()

      assert.is_true(callback_called)
      assert.equal(0, #feedkeys_calls)
    end)

    it('feeds key binding when completion is visible', function()
      mock_completion.is_completion_visible = function()
        return true
      end

      local callback_called = false
      keymap.setup({
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            defer_to_completion = true,
            desc = 'Tab with completion defer',
          },
        },
      })

      assert.equal(1, #set_keymaps)
      set_keymaps[1].callback()

      assert.is_false(callback_called)
      assert.equal(1, #feedkeys_calls)
    end)

    it('does not wrap callback when defer_to_completion is not set', function()
      mock_completion.is_completion_visible = function()
        return true
      end

      local callback_called = false
      keymap.setup({
        editor = {
          ['<tab>'] = {
            function()
              callback_called = true
            end,
            desc = 'Tab without defer',
          },
        },
      })

      assert.equal(1, #set_keymaps)
      set_keymaps[1].callback()

      assert.is_true(callback_called)
      assert.equal(0, #feedkeys_calls)
    end)
  end)
end)
