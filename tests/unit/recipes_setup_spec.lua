local config = require('opencode.config')

describe('opencode.setup recipes', function()
  local setup_modules = {
    'opencode.ui.highlight',
    'opencode.services.session_tab_persistence',
    'opencode.ui.permission_window',
    'opencode.ui.question_window',
    'opencode.commands',
    'opencode.ui.completion',
    'opencode.keymap',
    'opencode.ui.contextual_actions',
    'opencode.ui.autocmds',
    'opencode.ui.session_tab_notifications',
    'opencode.ui.program_status',
    'opencode.context',
    'opencode.ui.context_bar',
  }
  local module_names = vim.list_extend(vim.deepcopy(setup_modules), {
    'opencode',
    'opencode.state',
    'opencode.services.session_runtime',
    'opencode.commands.slash',
    'test_setup_recipe',
  })
  local saved_modules
  local saved_config
  local saved_schedule
  local saved_preload
  local calls
  local opencode

  before_each(function()
    saved_modules = {}
    for _, name in ipairs(module_names) do
      saved_modules[name] = package.loaded[name]
    end
    saved_config = config.values
    config.values = vim.deepcopy(config.defaults)
    saved_schedule = vim.schedule
    vim.schedule = function() end
    saved_preload = package.preload['test_setup_recipe']
    package.loaded['test_setup_recipe'] = nil
    package.preload['test_setup_recipe'] = nil
    calls = {}

    for _, name in ipairs(setup_modules) do
      local function setup()
        calls[#calls + 1] = name
      end
      package.loaded[name] = { setup = setup, setup_subscriptions = setup }
    end
    package.loaded['opencode.state'] = {
      session_tabs = { setup = function() end },
      store = { subscribe = function() end },
    }
    package.loaded['opencode.services.session_runtime'] = { setup_subscriptions = function() end }
    package.loaded['opencode.commands.slash'] = { execute_builtin = function() end }
    package.loaded['opencode'] = nil
    opencode = require('opencode')
  end)

  after_each(function()
    for _, name in ipairs(module_names) do
      package.loaded[name] = saved_modules[name]
    end
    package.preload['test_setup_recipe'] = saved_preload
    config.values = saved_config
    vim.schedule = saved_schedule
  end)

  it('still accepts setup without options', function()
    opencode.setup()

    assert.same(config.defaults, config.values)
    assert.equal('opencode.ui.context_bar', calls[#calls])
  end)

  it('applies recipe defaults before initialization and runs hooks afterward in order', function()
    local first_setup = package.loaded['opencode.ui.highlight'].setup
    package.loaded['opencode.ui.highlight'].setup = function()
      assert.equal('plan', config.default_mode)
      assert.equal('<leader>u', config.keymap_prefix)
      first_setup()
    end

    opencode.setup({
      keymap_prefix = '<leader>u',
      recipes = {
        {
          opts = { default_mode = 'plan', keymap_prefix = '<leader>r' },
          setup = function(module)
            assert.equal(opencode, module)
            assert.equal('opencode.ui.context_bar', calls[#calls])
            calls[#calls + 1] = 'recipe a'
          end,
        },
        {
          setup = function(module)
            assert.equal(opencode, module)
            assert.equal('recipe a', calls[#calls])
            calls[#calls + 1] = 'recipe b'
          end,
        },
      },
    })

    assert.equal('recipe b', calls[#calls])
  end)

  it('runs hooks only once, including when a hook calls setup again', function()
    local count = 0
    opencode.setup({
      recipes = {
        {
          setup = function(module)
            count = count + 1
            module.setup({ recipes = { 'opencode_missing_recipe' } })
          end,
        },
      },
    })
    opencode.setup({ recipes = { 'opencode_missing_recipe' } })

    assert.equal(1, count)
  end)

  it('allows a missing recipe to be fixed before retrying setup', function()
    assert.has_error(function()
      opencode.setup({ recipes = { 'test_setup_recipe' } })
    end)
    assert.same({}, calls)
    assert.same(config.defaults, config.values)

    local count = 0
    package.preload['test_setup_recipe'] = function()
      assert.same({}, calls)
      return {
        opts = { default_mode = 'plan' },
        setup = function(module)
          assert.equal(opencode, module)
          assert.equal('plan', config.default_mode)
          count = count + 1
        end,
      }
    end
    opencode.setup({ recipes = { 'test_setup_recipe' } })

    assert.equal(1, count)
  end)

  it('leaves the plugin initialized when a recipe hook fails', function()
    local count = 0
    assert.has_error(function()
      opencode.setup({
        recipes = {
          {
            setup = function()
              count = count + 1
              error('recipe hook failed')
            end,
          },
          {
            setup = function()
              count = count + 1
            end,
          },
        },
      })
    end, 'recipe hook failed')
    opencode.setup()

    assert.equal('opencode.ui.context_bar', calls[#calls])
    assert.equal(1, count)
  end)
end)
