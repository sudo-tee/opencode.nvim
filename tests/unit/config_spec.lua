-- tests/unit/config_spec.lua
-- Tests for the config module

local config = require('opencode.config')

describe('opencode.config', function()
  -- Save original config values
  local original_config

  -- Save the original config before all tests
  before_each(function()
    original_config = vim.deepcopy(config.values)
    -- Reset to default config
    config.values = vim.deepcopy(config.defaults)
  end)

  -- Restore original config after all tests
  after_each(function()
    config.values = original_config
  end)

  it('uses default values when no options are provided', function()
    config.setup(nil)
    assert.same(config.defaults, config.values)
  end)

  it('supports hiding the tab strip for a single session tab', function()
    config.setup({ ui = { hide_single_tab = true } })

    assert.is_true(config.values.ui.hide_single_tab)
  end)

  it('supports opening inline output session actions in new tabs', function()
    config.setup({ ui = { output = { actions = { open_in_new_tab = true } } } })

    assert.is_true(config.values.ui.output.actions.open_in_new_tab)
  end)

  it('merges user options with defaults', function()
    local custom_callback = function()
      return 'custom'
    end
    config.setup({
      hooks = {
        on_done_thinking = custom_callback,
      },
    })

    assert.equal(custom_callback, config.values.hooks.on_done_thinking)
    assert.same(config.defaults.keymap, config.values.keymap)
  end)

  it('maps output enter to target jump while keeping gf on file jump', function()
    local output_keymap = config.defaults.keymap.output_window

    assert.equal('jump_to_file', output_keymap['gf'][1])
    assert.equal('jump_to_target_at_cursor', output_keymap['<CR>'][1])
    assert.equal('jump_to_target_at_cursor', output_keymap['gd'][1])
  end)

  it('provides direct keymaps for the first nine session tabs', function()
    for index = 1, 9 do
      local mapping = config.defaults.keymap.editor['<leader>o' .. index]
      assert.same('select_session_tab', mapping[1])
      assert.same({ index }, mapping[2])
    end
  end)

  it('maps panel-tab close separately from closing the Opencode window', function()
    assert.equal('close', config.defaults.keymap.editor['<leader>oq'][1])
    assert.equal('close_session_tab', config.defaults.keymap.editor['<leader>oQ'][1])
  end)

  describe('update_keymap_prefix', function()
    local function test_prefix_update(opts)
      config.values.keymap = vim.deepcopy(opts.given)
      config.setup({ keymap_prefix = opts.new_prefix })
      assert.same(opts.expect, config.values.keymap)
    end

    it('remaps keys with matching prefix to new prefix', function()
      test_prefix_update({
        given = {
          editor = { ['<leader>og'] = { 'toggle' }, ['<esc>'] = { 'close' } },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = { 'toggle' }, ['<esc>'] = { 'close' } },
        },
      })
    end)

    it('does not remap when prefix equals default prefix', function()
      test_prefix_update({
        given = { editor = { ['<leader>og'] = { 'toggle' } } },
        new_prefix = '<leader>o',
        expect = { editor = { ['<leader>og'] = { 'toggle' } } },
      })
    end)

    it('does not remap when prefix is nil', function()
      test_prefix_update({
        given = { editor = { ['<leader>og'] = { 'toggle' } } },
        new_prefix = nil,
        expect = { editor = { ['<leader>og'] = { 'toggle' } } },
      })
    end)

    it('does not overwrite existing key in target position', function()
      test_prefix_update({
        given = {
          editor = {
            ['<leader>og'] = { 'toggle' },
            ['<space>og'] = { 'conflict' },
          },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = { 'conflict' } },
        },
      })
    end)

    it('preserves non-prefixed keys unchanged', function()
      test_prefix_update({
        given = {
          editor = { ['<leader>og'] = { 'toggle' }, ['<C-c>'] = { 'cancel' } },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = { 'toggle' }, ['<C-c>'] = { 'cancel' } },
        },
      })
    end)

    it('handles multiple categories independently', function()
      test_prefix_update({
        given = {
          editor = { ['<leader>og'] = { 'toggle' } },
          input_window = { ['<leader>oD'] = { 'debug' }, ['<cr>'] = { 'submit' } },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = { 'toggle' } },
          input_window = { ['<space>oD'] = { 'debug' }, ['<cr>'] = { 'submit' } },
        },
      })
    end)

    it('preserves false value for keymap with prefix', function()
      test_prefix_update({
        given = {
          editor = { ['<leader>og'] = false, ['<leader>oh'] = { 'history' } },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = false, ['<space>oh'] = { 'history' } },
        },
      })
    end)

    it('preserves false value for keymap without prefix', function()
      test_prefix_update({
        given = {
          editor = { ['<leader>og'] = { 'toggle' }, ['<C-c>'] = false },
        },
        new_prefix = '<space>o',
        expect = {
          editor = { ['<space>og'] = { 'toggle' }, ['<C-c>'] = false },
        },
      })
    end)
  end)
end)
