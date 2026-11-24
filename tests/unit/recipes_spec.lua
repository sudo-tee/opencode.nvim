local recipes = require('opencode.recipes')

describe('opencode.recipes', function()
  after_each(function()
    package.loaded['test_recipe_a'] = nil
    package.preload['test_recipe_a'] = nil
  end)

  it('accepts omitted options', function()
    local merged, loaded = recipes.resolve()

    assert.is_nil(merged)
    assert.same({}, loaded)
  end)

  it('returns the options unchanged when there are no recipes', function()
    local opts = { default_mode = 'plan' }
    local merged, loaded = recipes.resolve(opts)

    assert.equal(opts, merged)
    assert.same({}, loaded)
  end)

  it('accepts an empty recipe list', function()
    local merged, loaded = recipes.resolve({ recipes = {}, default_mode = 'plan' })

    assert.equal('plan', merged.default_mode)
    assert.same({}, loaded)
  end)

  it('requires recipes given as module names', function()
    local recipe = { opts = { default_mode = 'plan' } }
    package.preload['test_recipe_a'] = function()
      return recipe
    end

    local merged, loaded = recipes.resolve({ recipes = { 'test_recipe_a' } })

    assert.equal('plan', merged.default_mode)
    assert.equal(recipe, loaded[1])
  end)

  it('raises when a recipe module cannot be found', function()
    assert.has_error(function()
      recipes.resolve({ recipes = { 'opencode_missing_recipe' } })
    end)
  end)

  it('propagates errors while loading recipe modules', function()
    package.preload['test_recipe_a'] = function()
      error('recipe load failed')
    end

    assert.has_error(function()
      recipes.resolve({ recipes = { 'test_recipe_a' } })
    end, 'recipe load failed')
  end)

  it('merges recipe options in order, with user options winning', function()
    local merged = recipes.resolve({
      keymap_prefix = '<leader>u',
      recipes = {
        { opts = { keymap_prefix = '<leader>a', default_mode = 'plan', keymap = { editor = { a = 'x' } } } },
        { opts = { default_mode = 'build', keymap = { editor = { b = 'y' } } } },
      },
    })

    assert.equal('<leader>u', merged.keymap_prefix)
    assert.equal('build', merged.default_mode)
    assert.same({ a = 'x', b = 'y' }, merged.keymap.editor)
  end)

  it('preserves false overrides and replaces callbacks without chaining them', function()
    local recipe_hook = function() end
    local user_hook = function() end
    local merged = recipes.resolve({
      program_status = { enabled = false },
      hooks = { on_done_thinking = user_hook },
      recipes = {
        { opts = { program_status = { enabled = true, tmux = true }, hooks = { on_done_thinking = recipe_hook } } },
      },
    })

    assert.is_false(merged.program_status.enabled)
    assert.is_true(merged.program_status.tmux)
    assert.equal(user_hook, merged.hooks.on_done_thinking)
  end)

  it('does not mutate user options or recipe defaults', function()
    local recipe = { opts = { ui = { window_width = 0.4, input = { min_height = 4 } } } }
    local opts = { recipes = { recipe }, ui = { input = { min_height = 6 } } }
    local original = vim.deepcopy(opts)
    local merged = recipes.resolve(opts)

    assert.same(original, opts)
    merged.ui.window_width = 0.8
    merged.ui.input.min_height = 10
    assert.same(original, opts)
    assert.equal(recipe, opts.recipes[1])
  end)

  it('accepts options-only, setup-only, and empty recipes together', function()
    local setup = function() end
    local merged, loaded =
      recipes.resolve({ recipes = { {}, { opts = { default_mode = 'plan' } }, { setup = setup } } })

    assert.equal('plan', merged.default_mode)
    assert.equal(3, #loaded)
    assert.equal(setup, loaded[3].setup)
  end)

  it('runs recipe setups in order with the opencode module', function()
    local calls = {}
    local opencode = {}
    recipes.run({
      {
        setup = function(m)
          calls[#calls + 1] = { 'a', m }
        end,
      },
      { opts = {} },
      {
        setup = function(m)
          calls[#calls + 1] = { 'b', m }
        end,
      },
    }, opencode)

    assert.same({ { 'a', opencode }, { 'b', opencode } }, calls)
    assert.equal(opencode, calls[1][2])
  end)

  it('propagates errors from recipe setup', function()
    local later_setup_called = false
    assert.has_error(function()
      recipes.run({
        {
          setup = function()
            error('boom')
          end,
        },
        {
          setup = function()
            later_setup_called = true
          end,
        },
      }, {})
    end, 'boom')
    assert.is_false(later_setup_called)
  end)
end)
