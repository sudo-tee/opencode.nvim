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

  describe('snacks preview', function()
    local function pick_with(preview, preview_fn)
      base_picker.pick({
        title = 'Test',
        items = { { name = 'a' } },
        format_fn = function(item)
          return base_picker.create_picker_item({ { text = item.name } })
        end,
        actions = {},
        callback = function() end,
        preview = preview,
        preview_fn = preview_fn,
      })
    end

    it('sets preview to "file" when preview="file"', function()
      pick_with('file', nil)

      assert.equal('file', captured_opts.preview)
      assert.equal('select', captured_opts.layout.preset)
      assert.equal('main', captured_opts.layout.preview)
    end)

    it('sets preview to a function that calls preview_fn with a preview target when preview="custom"', function()
      local called_with = {}
      local preview_fn = function(item, target)
        called_with.item = item
        called_with.target = target
      end

      pick_with('custom', preview_fn)

      assert.is_function(captured_opts.preview)
      local test_item = { name = 'test_item' }
      local preview_lines
      local bufnr = vim.api.nvim_create_buf(false, true)
      local mock_preview = {
        reset = function() end,
        set_lines = function(_, lines)
          preview_lines = lines
        end,
      }
      local mock_ctx = {
        item = test_item,
        buf = bufnr,
        preview = mock_preview,
      }
      captured_opts.preview(mock_ctx)

      assert.equal(test_item, called_with.item)
      assert.is_table(called_with.target)
      assert.equal(bufnr, called_with.target:get_bufnr())
      assert.is_true(called_with.target:is_valid())
      called_with.target:set_lines({ 'preview' })
      assert.are.same({ 'preview' }, preview_lines)

      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('sets preview to a function returning false when preview is nil', function()
      pick_with(nil, nil)

      assert.is_function(captured_opts.preview)
      assert.is_false(captured_opts.preview())
      assert.equal('select', captured_opts.layout.preset)
      assert.is_false(captured_opts.layout.preview)
    end)

    it('uses snacks default preview pane layout when preview="custom"', function()
      pick_with('custom', function() end)

      assert.equal('default', captured_opts.layout.preset)
      assert.is_nil(captured_opts.layout.preview)
    end)

    it('disables preview layout when preview="custom" but preview_fn is missing', function()
      pick_with('custom', nil)

      assert.is_function(captured_opts.preview)
      assert.is_false(captured_opts.preview())
      assert.equal('select', captured_opts.layout.preset)
      assert.is_false(captured_opts.layout.preview)
    end)

    it('does not call preview_fn when preview="file"', function()
      local called = false
      pick_with('file', function()
        called = true
      end)

      assert.equal('file', captured_opts.preview)
      assert.is_false(called)
    end)
  end)
end)

describe('opencode.ui.base_picker fzf-lua preview', function()
  local base_picker
  local captured_fzf_opts
  local original_schedule
  local saved_modules
  local next_preview_buf

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
      ['fzf-lua'] = package.loaded['fzf-lua'],
      ['fzf-lua.previewer.builtin'] = package.loaded['fzf-lua.previewer.builtin'],
    }

    package.loaded['opencode.config'] = {
      ui = {
        picker_width = 80,
      },
      debug = {
        show_ids = false,
      },
    }

    package.loaded['opencode.util'] = {
      some = function(tbl, fn)
        for _, v in pairs(tbl) do
          if fn(v) then
            return true
          end
        end
        return false
      end,
    }

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
        return 'fzf'
      end,
    }

    captured_fzf_opts = nil

    package.loaded['fzf-lua'] = {
      fzf_exec = function(_, opts)
        captured_fzf_opts = opts
      end,
    }

    next_preview_buf = nil
    package.loaded['fzf-lua.previewer.builtin'] = {
      buffer_or_file = {
        extend = function()
          return {
            win = {
              validate_preview = function()
                return true
              end,
            },
            get_tmp_buffer = function()
              return next_preview_buf
            end,
            set_preview_buf = function(self, buf)
              self.preview_buf = buf
            end,
          }
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

  local function pick_with(preview, preview_fn)
    base_picker.pick({
      title = 'Test',
      items = { { name = 'a' } },
      format_fn = function(item)
        return base_picker.create_picker_item({ { text = item.name } })
      end,
      actions = {},
      callback = function() end,
      preview = preview,
      preview_fn = preview_fn,
    })
  end

  it('sets previewer to "builtin" when preview="file"', function()
    pick_with('file', nil)
    assert.equal('builtin', captured_fzf_opts.previewer)
  end)

  it('sets previewer to nil when preview is nil', function()
    pick_with(nil, nil)
    assert.is_nil(captured_fzf_opts.previewer)
  end)

  it('creates _ctor-based previewer when preview="custom"', function()
    pick_with('custom', function() end)
    assert.is_table(captured_fzf_opts.previewer)
    assert.is_function(captured_fzf_opts.previewer._ctor)
  end)

  it('sets previewer to nil when preview="custom" but no preview_fn', function()
    pick_with('custom', nil)
    assert.is_nil(captured_fzf_opts.previewer)
  end)

  it('passes a preview target to custom preview_fn', function()
    local received = {}
    pick_with('custom', function(item, target)
      received.item = item
      received.target = target
    end)

    next_preview_buf = vim.api.nvim_create_buf(false, true)
    local previewer = captured_fzf_opts.previewer._ctor()
    previewer:populate_preview_buf('1\001a')

    assert.equal('a', received.item.name)
    assert.equal(next_preview_buf, received.target:get_bufnr())
    assert.is_true(received.target:is_valid())

    received.target:set_lines({ 'fzf preview' })
    local lines = vim.api.nvim_buf_get_lines(next_preview_buf, 0, -1, false)
    assert.are.same({ 'fzf preview' }, lines)

    vim.api.nvim_buf_delete(next_preview_buf, { force = true })
  end)
end)
