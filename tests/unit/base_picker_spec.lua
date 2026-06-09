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
  local captured_fzf_finder
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

    captured_fzf_finder = nil
    captured_fzf_opts = nil

    package.loaded['fzf-lua'] = {
      fzf_exec = function(finder, opts)
        captured_fzf_finder = finder
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

  it('formats entries to the visible list width when preview is active', function()
    local observed_width

    base_picker.pick({
      title = 'Test',
      items = { { name = 'session' } },
      format_fn = function(item, width)
        observed_width = width
        return base_picker.create_picker_item({ { text = item.name } })
      end,
      actions = {},
      callback = function() end,
      preview = 'custom',
      preview_fn = function() end,
    })

    local emitted_lines = {}
    captured_fzf_finder(function(line)
      if line then
        table.insert(emitted_lines, line)
      end
    end)

    -- picker_width=80 with preview: window=80+8=88, list pane=floor(88*0.4)-4=31
    assert.equal(31, observed_width)
    assert.are.same({ '1\001session' }, emitted_lines)
    assert.equal(88, captured_fzf_opts.winopts.width)
  end)
end)

describe('opencode.ui.base_picker create_time_picker_item alignment', function()
  local base_picker
  local original_schedule
  local saved_modules
  local mock_config

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
    }

    mock_config = {
      ui = {
        picker_width = 80,
        output = { time_format = nil },
      },
      debug = { show_ids = false },
    }
    package.loaded['opencode.config'] = mock_config

    -- Provide a format_time that mimics real behavior: variable-width output
    -- depending on how old the timestamp is relative to "now".
    package.loaded['opencode.util'] = {
      format_time = function(timestamp)
        if not timestamp then
          return ''
        end
        local now = os.time()
        local same_day = os.date('%Y-%m-%d') == os.date('%Y-%m-%d', timestamp)
        local same_year = os.date('%Y') == os.date('%Y', timestamp)
        local time_part = os.date('%H:%M', timestamp)
        if same_day then
          return time_part -- e.g. "10:35"
        elseif same_year then
          return os.date('%d %b', timestamp) .. ' ' .. time_part -- e.g. "09 Jun 10:35"
        else
          return os.date('%d %b %Y', timestamp) .. ' ' .. time_part -- e.g. "09 Jun 2024 10:35"
        end
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
        return 'snacks'
      end,
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

  it('produces identical total width for timestamps of different ages', function()
    local now = os.time()
    local same_day_ts = now - 3600 -- 1 hour ago
    local same_year_ts = now - 86400 * 60 -- ~2 months ago
    local diff_year_ts = 0 -- epoch (1970)

    local width = 80
    local format_time = package.loaded['opencode.util'].format_time
    local max_tw = math.max(#format_time(same_day_ts), #format_time(same_year_ts), #format_time(diff_year_ts))

    local item_today = base_picker.create_time_picker_item('Session A', same_day_ts, nil, width, max_tw)
    local item_month = base_picker.create_time_picker_item('Session B', same_year_ts, nil, width, max_tw)
    local item_old = base_picker.create_time_picker_item('Session C', diff_year_ts, nil, width, max_tw)

    local str_today = item_today:to_string()
    local str_month = item_month:to_string()
    local str_old = item_old:to_string()

    assert.equal(#str_today, #str_month, 'same-day and same-year items should have equal width')
    assert.equal(#str_today, #str_old, 'same-day and different-year items should have equal width')
  end)

  it('to_string width matches the requested item width exactly', function()
    local width = 60

    local item = base_picker.create_time_picker_item('Session Title', 0, nil, width)
    local str = item:to_string()

    assert.equal(width, #str, 'to_string() output should be exactly item_width chars')
  end)

  it('right-aligns time within a fixed-width column', function()
    local now = os.time()
    local same_day_ts = now - 3600

    local width = 80
    local max_tw = #package.loaded['opencode.util'].format_time(same_day_ts)
    local item = base_picker.create_time_picker_item('Title', same_day_ts, nil, width, max_tw)
    local str = item:to_string()

    local time_str = package.loaded['opencode.util'].format_time(same_day_ts)
    assert.is_truthy(str:match(time_str .. '$'), 'time string should be at the right edge')
  end)

  it('max_time_width returns the width of the longest formatted timestamp', function()
    local now = os.time()
    local items = {
      { time = now - 3600 }, -- same-day
      { time = now - 86400 * 60 }, -- same-year
      { time = 0 }, -- different year (longest)
    }

    local max_tw = base_picker.max_time_width(items, function(item)
      return item.time
    end)

    local format_time = package.loaded['opencode.util'].format_time
    local expected = math.max(#format_time(items[1].time), #format_time(items[2].time), #format_time(items[3].time))
    assert.equal(expected, max_tw)
  end)

  it('max_time_width returns 0 for empty items', function()
    local max_tw = base_picker.max_time_width({}, function(item)
      return item.time
    end)
    assert.equal(0, max_tw)
  end)

  it('max_time_width returns 0 when no items have timestamps', function()
    local items = { { name = 'a' }, { name = 'b' } }
    local max_tw = base_picker.max_time_width(items, function(item)
      return item.time -- nil
    end)
    assert.equal(0, max_tw)
  end)

  it('uses only same-day width when all timestamps are from today', function()
    local now = os.time()
    local items = {
      { time = now - 60 },
      { time = now - 3600 },
    }

    local max_tw = base_picker.max_time_width(items, function(item)
      return item.time
    end)

    local format_time = package.loaded['opencode.util'].format_time
    -- All same-day, so max_tw should equal the short time width
    assert.equal(#format_time(now - 60), max_tw)
  end)
end)
