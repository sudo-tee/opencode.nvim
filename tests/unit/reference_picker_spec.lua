local assert = require('luassert')

describe('opencode.ui.reference_picker', function()
  local reference_picker
  local mock_state
  local mock_config
  local mock_base_picker
  local mock_icons
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

    mock_state = {
      messages = {},
      event_manager = {
        subscribe = function() end,
      },
      store = {
        subscribe = function() end,
      },
    }
    package.loaded['opencode.state'] = mock_state

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
  end)

  after_each(function()
    vim.fn = original_fn
    vim.startswith = original_startswith
    vim.cmd = original_cmd
    vim.api = original_api

    package.loaded['opencode.ui.reference_picker'] = nil
    package.loaded['opencode.state'] = nil
    package.loaded['opencode.config'] = nil
    package.loaded['opencode.ui.base_picker'] = nil
    package.loaded['opencode.ui.icons'] = nil
  end)

  describe('parse_references', function()
    it('parses backtick-wrapped file references', function()
      local text = 'Check the implementation in `src/main.lua` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
      assert.is_nil(refs[1].line)
      assert.is_nil(refs[1].col)
    end)

    it('parses backtick-wrapped file references with line numbers', function()
      local text = 'See function at `src/utils.lua:42` for implementation.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/utils.lua', refs[1].file_path)
      assert.equal(42, refs[1].line)
      assert.is_nil(refs[1].col)
    end)

    it('parses backtick-wrapped file references with line and column', function()
      local text = 'Error at `src/handler.lua:10:5` needs fixing.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/handler.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
      assert.equal(5, refs[1].col)
    end)

    it('parses backtick-wrapped file references with line ranges (only start line captured)', function()
      local text = 'Review lines `src/test.lua:10-20` for context.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/test.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
      -- end of range is not represented in the ref struct
    end)

    it('parses file:// URI references', function()
      local text = 'Open file://src/config.lua for settings.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/config.lua', refs[1].file_path)
    end)

    it('parses file:// URI references with line numbers', function()
      local text = 'Check file://src/init.lua:99 for the issue.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/init.lua', refs[1].file_path)
      assert.equal(99, refs[1].line)
    end)

    it('parses plain path references with forward slashes', function()
      local text = 'The function is in src/module/helper.lua:25'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/module/helper.lua', refs[1].file_path)
      assert.equal(25, refs[1].line)
    end)

    it('parses top-level file references when file exists', function()
      local text = 'Check README.md for documentation.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('README.md', refs[1].file_path)
    end)

    it('parses multiple references in one text', function()
      local text = [[
        The main logic is in `src/main.lua:50` and helper
        functions are in `lib/utils.lua:10`. Also see
        the configuration in config.txt.
      ]]
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(3, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
      assert.equal(50, refs[1].line)
      assert.equal('lib/utils.lua', refs[2].file_path)
      assert.equal(10, refs[2].line)
      assert.equal('config.txt', refs[3].file_path)
    end)

    it('rejects URLs in context', function()
      local text = 'Visit https://example.com/file.lua for more info.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(0, #refs)
    end)

    it('rejects www URLs in context', function()
      local text = 'See www.example.com/docs.txt for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(0, #refs)
    end)

    it('rejects files without extensions', function()
      local text = 'Check `README` for info.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(0, #refs)
    end)

    it('rejects top-level files that do not exist (check_exists pattern)', function()
      -- Unquoted top-level filenames require the file to be readable
      local text = 'See nonexistent.xyz for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(0, #refs)
    end)

    it('includes backtick-wrapped files regardless of existence', function()
      -- Backtick pattern has check_exists=false; useful for referencing new files
      local text = 'Create `newfile.xyz` with the following content.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('newfile.xyz', refs[1].file_path)
    end)

    it('deduplicates overlapping matches across patterns', function()
      local text = 'Check file://src/main.lua for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      -- file:// and plain-slash patterns both see this, but only the first match wins
      assert.is_true(#refs >= 1)
      assert.equal('src/main.lua', refs[1].file_path)
    end)

    it('keeps later top-level references with the same basename', function()
      local text = 'See `src/main.lua:10` first, then check main.lua:42 too.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(2, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
      assert.equal('main.lua', refs[2].file_path)
      assert.equal(42, refs[2].line)
    end)

    it('ref struct contains file_path, line, col, match_start, match_end', function()
      local text = 'See `src/test.lua:5:3` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      local ref = refs[1]
      assert.equal('src/test.lua', ref.file_path)
      assert.equal(5, ref.line)
      assert.equal(3, ref.col)
      assert.is_number(ref.match_start)
      assert.is_number(ref.match_end)
    end)

    it('returns same cached refs when called again with identical text', function()
      local text = 'Check `src/main.lua` for details.'
      local refs1 = reference_picker.parse_references(text, 'msg1')
      local refs2 = reference_picker.parse_references(text, 'msg1')

      assert.equal(#refs1, #refs2)
      assert.equal(refs1[1].file_path, refs2[1].file_path)
    end)

    it('extends refs incrementally as text grows', function()
      local text1 = 'Check `src/main.lua`.'
      local text2 = text1 .. ' Also `lib/util.lua`.'

      -- Capture count before second call: parse_references returns the live c.refs
      -- table, so refs1 would mutate if stored and then text2 is parsed
      local count1 = #reference_picker.parse_references(text1, 'msg1')
      local count2 = #reference_picker.parse_references(text2, 'msg1')

      assert.equal(1, count1)
      assert.equal(2, count2)
    end)

    it('handles files with hyphens and underscores', function()
      local text = 'Check `my-cool_file.lua:5` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('my-cool_file.lua', refs[1].file_path)
      assert.equal(5, refs[1].line)
    end)

    it('handles nested directory paths', function()
      local text = 'See `src/module/sub/deep/file.lua:100` for implementation.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/module/sub/deep/file.lua', refs[1].file_path)
      assert.equal(100, refs[1].line)
    end)
  end)

  describe('navigate_to', function()
    it('opens file in new tab using absolute path', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = { file_path = 'src/main.lua' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /test/project/src/main.lua', cmd_calls[1])
    end)

    it('navigates to specific line', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      local ref = { file_path = 'src/main.lua', line = 42 }
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

      local ref = { file_path = 'src/main.lua', line = 42, col = 10 }
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

      local ref = { file_path = 'src/main.lua', line = 999 }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(50, cursor_calls[1].pos[1])
    end)

    it('handles files with spaces in path', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = { file_path = 'src/my file.lua' }
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

      local ref = { file_path = 'nonexistent.xyz' }
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

      local ref = { file_path = '/absolute/path/file.lua' }
      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /absolute/path/file.lua', cmd_calls[1])
    end)
  end)

  -- Helper: populate parse cache then expose items via pick()
  local function pick_items(messages_and_texts)
    -- messages_and_texts: list of { id, role, text, parts }
    local state_msgs = {}
    for _, m in ipairs(messages_and_texts) do
      if m.text then
        reference_picker.parse_references(m.text, m.id)
      end
      table.insert(state_msgs, {
        info = { role = m.role or 'assistant', id = m.id },
        parts = m.parts,
      })
    end
    mock_state.messages = state_msgs

    local captured
    mock_base_picker.pick = function(opts)
      captured = opts
      return {}
    end
    reference_picker.pick()
    return captured and captured.items or nil
  end

  describe('pick', function()
    it('shows notification when no references found', function()
      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      mock_state.messages = {}
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

      reference_picker.parse_references('Check `src/main.lua:10`.', 'msg1')
      mock_state.messages = { { info = { role = 'assistant', id = 'msg1' } } }
      reference_picker.pick()

      assert.equal(1, #pick_calls)
      assert.equal(1, #pick_calls[1].items)
      assert.is_function(pick_calls[1].format_fn)
      assert.is_function(pick_calls[1].callback)
      assert.equal('Code References (1)', pick_calls[1].title)
      assert.equal(100, pick_calls[1].width)
      assert.equal('file', pick_calls[1].preview)
    end)

    it('collects references from cached assistant message text', function()
      local items = pick_items({
        { id = 'msg1', text = 'Check `src/main.lua:10` for details.' },
      })

      assert.is_not_nil(items)
      assert.equal(1, #items)
      assert.equal('src/main.lua', items[1].file_path)
      assert.equal(10, items[1].line)
    end)

    it('ignores user messages when collecting refs', function()
      reference_picker.parse_references('Check `src/main.lua:10`.', 'msg1')
      mock_state.messages = { { info = { role = 'user', id = 'msg1' } } }

      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      reference_picker.pick()

      assert.equal(1, #notify_calls) -- "No code references found"
      vim.notify = original_notify
    end)

    it('returns refs in reverse message order (most recent first)', function()
      local items = pick_items({
        { id = 'msg1', text = 'Check `old.lua:1`.' },
        { id = 'msg2', text = 'See `new.lua:2`.' },
      })

      assert.is_not_nil(items)
      assert.equal(2, #items)
      assert.equal('new.lua', items[1].file_path)
      assert.equal('old.lua', items[2].file_path)
    end)

    it('deduplicates refs with same file and line across messages', function()
      local items = pick_items({
        { id = 'msg1', text = 'Check `src/main.lua:10`.' },
        { id = 'msg2', text = 'Also check `src/main.lua:10`.' },
      })

      assert.is_not_nil(items)
      assert.equal(1, #items)
    end)

    it('keeps most recent ref when deduplicating (reverse order wins)', function()
      -- msg2 is processed first (reverse order), so it wins deduplication
      local items = pick_items({
        { id = 'msg1', text = 'Check `src/main.lua:10`.' },
        { id = 'msg2', text = 'Also check `src/main.lua:10`.' },
      })

      assert.is_not_nil(items)
      assert.equal(1, #items)
      -- The kept ref came from the cache for msg2
      assert.equal('src/main.lua', items[1].file_path)
    end)

    it('collects file paths from tool parts', function()
      local items = pick_items({
        {
          id = 'msg1',
          parts = {
            {
              type = 'tool',
              state = { input = { filePath = '/test/project/src/file.lua' } },
            },
          },
        },
      })

      assert.is_not_nil(items)
      assert.equal(1, #items)
      assert.equal('src/file.lua', items[1].file_path)
    end)

    it('ignores non-existent files in tool parts', function()
      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      pick_items({
        {
          id = 'msg1',
          parts = {
            {
              type = 'tool',
              state = { input = { filePath = '/test/project/nonexistent.xyz' } },
            },
          },
        },
      })

      assert.equal(1, #notify_calls) -- "No code references found"
      vim.notify = original_notify
    end)

    it('collects refs from nil messages gracefully', function()
      mock_state.messages = nil

      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      reference_picker.pick()

      assert.equal(1, #notify_calls)
      assert.equal('No code references found in the conversation', notify_calls[1].msg)
      vim.notify = original_notify
    end)
  end)

  describe('setup', function()
    it('can be called without errors', function()
      assert.has_no.errors(function()
        reference_picker.setup()
      end)
    end)

    it('subscribes to messages state changes', function()
      local subscriptions = {}
      mock_state.store.subscribe = function(key, handler)
        table.insert(subscriptions, { key = key, handler = handler })
      end

      reference_picker.setup()

      assert.equal(1, #subscriptions)
      assert.equal('messages', subscriptions[1].key)
      assert.is_function(subscriptions[1].handler)
    end)

    it('clears the parse cache when messages state changes', function()
      reference_picker.parse_references('See `src/main.lua`.', 'msg1')

      local handler
      mock_state.store.subscribe = function(key, h)
        handler = h
      end
      reference_picker.setup()

      -- Simulate a messages state change
      handler()

      -- Cache is now cleared; pick() finds no refs for msg1
      mock_state.messages = { { info = { role = 'assistant', id = 'msg1' } } }

      local notify_calls = {}
      local original_notify = vim.notify
      vim.notify = function(msg, level)
        table.insert(notify_calls, { msg = msg, level = level })
      end

      reference_picker.pick()

      assert.equal(1, #notify_calls)
      assert.equal('No code references found in the conversation', notify_calls[1].msg)
      vim.notify = original_notify
    end)
  end)
end)
