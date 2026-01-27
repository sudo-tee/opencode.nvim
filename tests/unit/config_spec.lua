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

  it('merges user options with defaults', function()
    local custom_callback = function()
      return 'custom'
    end
    config.setup({
      command_callback = custom_callback,
    })

    assert.equal(custom_callback, config.values.command_callback)
    assert.same(config.defaults.keymap, config.values.keymap)
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
