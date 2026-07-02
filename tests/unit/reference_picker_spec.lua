local assert = require('luassert')

describe('opencode.ui.reference_picker', function()
  local reference_picker
  local mock_config
  local mock_base_picker
  local mock_icons
  local reference_facts
  local original_fn
  local original_startswith
  local original_cmd
  local original_api

  before_each(function()
    original_fn = vim.fn
    original_startswith = vim.startswith
    original_cmd = vim.cmd
    original_api = vim.api

    vim.fn = vim.tbl_extend('force', vim.fn or {}, {
      getcwd = function()
        return '/test/project'
      end,
      filereadable = function(path)
        if path:match('%.lua$') or path:match('%.txt$') or path:match('%.md$') then
          return 1
        end
        return 0
      end,
      fnameescape = function(path)
        return path:gsub(' ', '\\ ')
      end,
      fnamemodify = function(path, modifier)
        if modifier == ':~:.' then
          return path:gsub('^/test/project/', '')
        end
        return path
      end,
    })

    vim.startswith = function(str, prefix)
      return str:sub(1, #prefix) == prefix
    end

    vim.cmd = function() end

    vim.api = vim.tbl_extend('force', vim.api or {}, {
      nvim_win_set_cursor = function() end,
      nvim_buf_line_count = function()
        return 100
      end,
    })

    mock_config = {
      ui = {
        picker_width = 100,
        picker = {},
      },
    }
    package.loaded['opencode.config'] = mock_config

    mock_base_picker = {
      pick = function()
        return {}
      end,
      create_time_picker_item = function(text)
        return { text = text }
      end,
    }
    package.loaded['opencode.ui.base_picker'] = mock_base_picker

    mock_icons = {
      get = function(name)
        if name == 'file' then
          return '📄'
        end
        return ''
      end,
    }
    package.loaded['opencode.ui.icons'] = mock_icons

    reference_picker = require('opencode.ui.reference_picker')
    package.loaded['opencode.ui.reference_parser'] = nil
    reference_facts = require('opencode.ui.reference_facts')
    reference_facts.clear()
  end)

  after_each(function()
    vim.fn = original_fn
    vim.startswith = original_startswith
    vim.cmd = original_cmd
    vim.api = original_api

    package.loaded['opencode.ui.reference_picker'] = nil
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.ui.base_picker'] = nil
    package.loaded['opencode.ui.icons'] = nil
    package.loaded['opencode.ui.reference_facts'] = nil
    package.loaded['opencode.ui.reference_parser'] = nil
  end)

  describe('navigate_to', function()
    it('opens file in new tab using absolute path', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = { path = 'src/main.lua' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /test/project/src/main.lua', cmd_calls[1])
    end)

    it('navigates to specific line', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      local ref = { path = 'src/main.lua', line = 42 }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(42, cursor_calls[1].pos[1])
      assert.equal(0, cursor_calls[1].pos[2])
    end)

    it('navigates to specific line and column (col is 0-indexed)', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      local ref = { path = 'src/main.lua', line = 42, col = 10 }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(42, cursor_calls[1].pos[1])
      assert.equal(9, cursor_calls[1].pos[2]) -- col - 1
    end)

    it('clamps line to buffer length', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end
      vim.api.nvim_buf_line_count = function()
        return 50
      end

      local ref = { path = 'src/main.lua', line = 999 }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(50, cursor_calls[1].pos[1])
    end)

    it('handles files with spaces in path', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = { path = 'src/my file.lua' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /test/project/src/my\\ file.lua', cmd_calls[1])
    end)

    it('shows warning and returns when file does not exist', function()
      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      local ref = { path = 'nonexistent.xyz' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #notify_calls)
      assert.equal(vim.log.levels.WARN, notify_calls[1].level)
      vim.notify = original_notify
    end)

    it('accepts absolute file paths', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end
      vim.fn.filereadable = function(path)
        if path == '/absolute/path/file.lua' then
          return 1
        end
        return 0
      end

      local ref = { path = '/absolute/path/file.lua' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /absolute/path/file.lua', cmd_calls[1])
    end)
  end)

  local function rebuild_facts(messages)
    reference_facts.rebuild('ses_1', messages)
  end

  describe('pick', function()
    it('shows notification when no references found', function()
      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      reference_facts.clear()
      reference_picker.pick()

      assert.equal(1, #notify_calls)
      assert.equal('No code references found in the conversation', notify_calls[1].msg)
      assert.equal(vim.log.levels.INFO, notify_calls[1].level)
      vim.notify = original_notify
    end)

    it('passes correct options to base_picker.pick', function()
      local pick_calls = {}
      mock_base_picker.pick = function(opts)
        table.insert(pick_calls, opts)
        return {}
      end

      rebuild_facts({
        {
          info = { role = 'assistant', id = 'msg1', sessionID = 'ses_1' },
          parts = {
            { type = 'text', id = 'part1', text = 'Check `src/main.lua:10`.' },
          },
        },
      })
      reference_picker.pick()

      assert.equal(1, #pick_calls)
      assert.equal(1, #pick_calls[1].items)
      assert.is_function(pick_calls[1].format_fn)
      assert.is_function(pick_calls[1].callback)
      assert.equal('Code References (1)', pick_calls[1].title)
      assert.equal(100, pick_calls[1].width)
      assert.equal('file', pick_calls[1].preview)
    end)

    it('uses references from reference_facts', function()
      rebuild_facts({
        {
          info = { role = 'assistant', id = 'msg1', sessionID = 'ses_1' },
          parts = {
            { type = 'text', id = 'part1', text = 'Check `src/main.lua:10` for details.' },
          },
        },
      })
      local captured
      mock_base_picker.pick = function(opts)
        captured = opts
        return {}
      end

      reference_picker.pick()
      local items = captured and captured.items

      assert.is_not_nil(items)
      assert.equal(1, #items)
      assert.equal('src/main.lua', items[1].path)
      assert.equal(10, items[1].line)
    end)

    it('deduplicates picker display items by path and line without changing facts', function()
      rebuild_facts({
        {
          info = { role = 'assistant', id = 'msg1', sessionID = 'ses_1' },
          parts = {
            { type = 'text', id = 'part1', text = 'First `src/main.lua:10`.' },
            { type = 'text', id = 'part2', text = 'Second `src/main.lua:10`.' },
          },
        },
      })
      local captured
      mock_base_picker.pick = function(opts)
        captured = opts
        return {}
      end

      reference_picker.pick()

      assert.equal(1, #captured.items)
      assert.equal('part1', captured.items[1].part_id)
      assert.equal('Code References (1)', captured.title)
    end)
  end)
end)
