describe('opencode.ui.base_picker', function()
  local base_picker
  local captured_opts
  local original_schedule
  local saved_modules

  before_each(function()
    original_schedule = vim.schedule
    vim.schedule = function(fn)
      fn()
    end

    saved_modules = {
      ['opencode.config'] = package.loaded['opencode.config'],
      ['opencode.util'] = package.loaded['opencode.util'],
      ['opencode.promise'] = package.loaded['opencode.promise'],
      ['opencode.ui.picker'] = package.loaded['opencode.ui.picker'],
      ['opencode.ui.base_picker'] = package.loaded['opencode.ui.base_picker'],
      ['snacks'] = package.loaded['snacks'],
    }

    package.loaded['opencode.config'] = {
      ui = {
        picker_width = 80,
      },
      debug = {
        show_ids = false,
      },
    }

    package.loaded['opencode.util'] = {}

    package.loaded['opencode.promise'] = {
      wrap = function(value)
        return {
          and_then = function(_, cb)
            cb(value)
          end,
        }
      end,
    }

    package.loaded['opencode.ui.picker'] = {
      get_best_picker = function()
        return 'snacks'
      end,
    }

    captured_opts = nil
    package.loaded['snacks'] = {
      picker = {
        pick = function(opts)
          captured_opts = opts
        end,
      },
    }

    package.loaded['opencode.ui.base_picker'] = nil
    base_picker = require('opencode.ui.base_picker')
  end)

  after_each(function()
    vim.schedule = original_schedule

    for module_name, module_value in pairs(saved_modules) do
      package.loaded[module_name] = module_value
    end
  end)

  it('configures snacks picker to preserve source ordering', function()
    base_picker.pick({
      title = 'Select model',
      items = {
        { name = 'favorite model' },
        { name = 'other model' },
      },
      format_fn = function(item)
        return base_picker.create_picker_item({
          { text = item.name },
        })
      end,
      actions = {},
      callback = function() end,
    })

    assert.is_not_nil(captured_opts)
    assert.are.same(false, captured_opts.matcher.sort_empty)
    assert.are.same({ 'score:desc', 'idx' }, captured_opts.sort.fields)
  end)

  it('assigns stable idx values in snacks transform', function()
    base_picker.pick({
      title = 'Select model',
      items = {
        { name = 'favorite model' },
      },
      format_fn = function(item)
        return base_picker.create_picker_item({
          { text = item.name },
        })
      end,
      actions = {},
      callback = function() end,
    })

    assert.is_not_nil(captured_opts)

    local item = { name = 'favorite model' }
    captured_opts.transform(item, { idx = 7 })

    assert.equal(7, item.idx)
    assert.equal('favorite model', item.text)
  end)

  it('boosts score for favorites in snacks transform', function()
    base_picker.pick({
      title = 'Select model',
      items = {
        { name = 'favorite model', favorite_index = 1 },
      },
      format_fn = function(item)
        return base_picker.create_picker_item({
          { text = item.name },
        })
      end,
      actions = {},
      callback = function() end,
    })

    assert.is_not_nil(captured_opts)

    local item = { name = 'favorite model', favorite_index = 2 }
    captured_opts.transform(item, { idx = 3 })

    assert.equal(998000, item.score_add)
  end)
end)
