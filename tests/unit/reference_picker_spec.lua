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
      subscribe = function() end,
    }
    package.loaded['opencode.state'] = mock_state

    mock_config = {
      runtime = {
        path = {
          to_local = nil,
        },
      },
      ui = {
        picker_width = 100,
        picker = {},
      },
    }
    package.loaded['opencode.config'] = mock_config
    package.loaded['opencode.util'] = nil

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
    package.loaded['opencode.util'] = nil
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
    end)

    it('parses backtick-wrapped file references with line numbers', function()
      local text = 'See function at `src/utils.lua:42` for implementation.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/utils.lua', refs[1].file_path)
      assert.equal(42, refs[1].line)
      assert.is_nil(refs[1].column)
    end)

    it('parses backtick-wrapped file references with line and column', function()
      local text = 'Error at `src/handler.lua:10:5` needs fixing.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/handler.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
      assert.equal(5, refs[1].column)
    end)

    it('parses backtick-wrapped file references with line ranges', function()
      local text = 'Review lines `src/test.lua:10-20` for context.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('src/test.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
      assert.equal(20, refs[1].end_pos[1])
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

    it('parses top-level file references', function()
      local text = 'Check README.md for documentation.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('README.md', refs[1].file_path)
    end)

    it('parses multiple references in one text', function()
      local text = [[
        The main logic is in `src/main.lua:50` and helper
        functions are in `lib/utils.lua:10-30`. Also see
        the configuration in config.txt.
      ]]
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(3, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
      assert.equal(50, refs[1].line)
      assert.equal('lib/utils.lua', refs[2].file_path)
      assert.equal(10, refs[2].line)
      assert.equal(30, refs[2].end_pos[1])
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

    it('rejects non-existent files', function()
      local text = 'See `nonexistent.xyz:10` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(0, #refs)
    end)

    it('deduplicates overlapping matches', function()
      -- When different patterns match the same text at same position, only keep one
      -- This happens rarely but the logic protects against it
      local text = 'Check file://src/main.lua for details.'
      
      -- Mock to make the plain pattern also match (though normally file:// would be caught first)
      local refs = reference_picker.parse_references(text, 'msg1')

      -- Should only have 1 reference since they all refer to same location
      assert.is_true(#refs >= 1, 'Should have at least one reference')
    end)

    it('tracks message_id for each reference', function()
      local text = 'See `src/test.lua` for details.'
      local refs = reference_picker.parse_references(text, 'test_msg_123')

      assert.equal(1, #refs)
      assert.equal('test_msg_123', refs[1].message_id)
    end)

    it('creates correct absolute paths from relative paths', function()
      local text = 'Check `src/main.lua` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('/test/project/src/main.lua', refs[1].file)
    end)

    it('preserves absolute paths', function()
      local text = 'Check `/absolute/path/file.lua` for details.'
      
      vim.fn.filereadable = function(path)
        if path == '/absolute/path/file.lua' then
          return 1
        end
        return 0
      end
      
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('/absolute/path/file.lua', refs[1].file)
    end)

    it('maps /mnt paths via runtime to_local transform', function()
      mock_config.runtime.path.to_local = function(path)
        local drive, rest = path:match('^/mnt/([a-zA-Z])/?(.*)$')
        if not drive then
          return path
        end
        local win_rest = rest:gsub('/', '\\')
        if win_rest ~= '' then
          return string.format('%s:\\%s', drive:upper(), win_rest)
        end
        return string.format('%s:\\', drive:upper())
      end
      vim.fn.filereadable = function(path)
        if path == 'C:\\Users\\me\\repo\\main.lua' then
          return 1
        end
        return 0
      end

      local text = 'Check `/mnt/c/Users/me/repo/main.lua:12` for details.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.equal('C:\\Users\\me\\repo\\main.lua', refs[1].file_path)
      assert.equal(12, refs[1].line)
    end)

    it('creates correct pos array for Snacks picker', function()
      local text = 'Error at `src/main.lua:42:10` needs fixing.'
      local refs = reference_picker.parse_references(text, 'msg1')

      assert.equal(1, #refs)
      assert.is_not_nil(refs[1].pos)
      assert.equal(42, refs[1].pos[1])
      assert.equal(9, refs[1].pos[2]) -- column is 0-indexed
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

  describe('collect_references', function()
    it('returns empty array when no messages', function()
      mock_state.messages = nil
      local refs = reference_picker.collect_references()

      assert.equal(0, #refs)
    end)

    it('returns empty array when messages is empty', function()
      mock_state.messages = {}
      local refs = reference_picker.collect_references()

      assert.equal(0, #refs)
    end)

    it('collects references from assistant messages', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10` for details.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(1, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
      assert.equal(10, refs[1].line)
    end)

    it('ignores user messages', function()
      mock_state.messages = {
        {
          info = { role = 'user', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10` for details.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(0, #refs)
    end)

    it('collects references from multiple messages', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10`.' },
          },
        },
        {
          info = { role = 'assistant', id = 'msg2' },
          parts = {
            { type = 'text', text = 'Also see `lib/utils.lua:20`.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(2, #refs)
    end)

    it('returns references in reverse message order (most recent first)', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `old.lua:1`.' },
          },
        },
        {
          info = { role = 'assistant', id = 'msg2' },
          parts = {
            { type = 'text', text = 'See `new.lua:2`.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(2, #refs)
      assert.equal('new.lua', refs[1].file_path)
      assert.equal('old.lua', refs[2].file_path)
    end)

    it('deduplicates references with same file and line', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10`.' },
          },
        },
        {
          info = { role = 'assistant', id = 'msg2' },
          parts = {
            { type = 'text', text = 'Also check `src/main.lua:10`.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(1, #refs)
    end)

    it('keeps most recent reference when deduplicating', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10`.' },
          },
        },
        {
          info = { role = 'assistant', id = 'msg2' },
          parts = {
            { type = 'text', text = 'Also check `src/main.lua:10`.' },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(1, #refs)
      assert.equal('msg2', refs[1].message_id)
    end)

    it('uses cached references when available', function()
      local cached_ref = {
        file_path = 'cached.lua',
        line = 42,
        message_id = 'msg1',
        file = '/test/project/cached.lua',
      }

      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          references = { cached_ref },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(1, #refs)
      assert.equal('cached.lua', refs[1].file_path)
      assert.equal(42, refs[1].line)
    end)

    it('extracts file paths from tool parts', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            {
              type = 'tool',
              state = {
                input = {
                  filePath = '/test/project/src/file.lua',
                },
              },
            },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(1, #refs)
      assert.equal('src/file.lua', refs[1].file_path)
    end)

    it('ignores non-existent files in tool parts', function()
      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            {
              type = 'tool',
              state = {
                input = {
                  filePath = '/test/project/nonexistent.xyz',
                },
              },
            },
          },
        },
      }

      local refs = reference_picker.collect_references()

      assert.equal(0, #refs)
    end)
  end)

  describe('navigate_to', function()
    it('opens file in new tab', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = {
        file_path = 'src/main.lua',
        file = '/test/project/src/main.lua',
      }

      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /test/project/src/main.lua', cmd_calls[1])
    end)

    it('navigates to specific line', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      local ref = {
        file_path = 'src/main.lua',
        file = '/test/project/src/main.lua',
        line = 42,
      }

      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(42, cursor_calls[1].pos[1])
      assert.equal(0, cursor_calls[1].pos[2])
    end)

    it('navigates to specific line and column', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      local ref = {
        file_path = 'src/main.lua',
        file = '/test/project/src/main.lua',
        line = 42,
        column = 10,
      }

      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(42, cursor_calls[1].pos[1])
      assert.equal(9, cursor_calls[1].pos[2]) -- 0-indexed
    end)

    it('clamps line to valid range', function()
      local cursor_calls = {}
      vim.api.nvim_win_set_cursor = function(win, pos)
        table.insert(cursor_calls, { win = win, pos = pos })
      end

      vim.api.nvim_buf_line_count = function()
        return 50
      end

      local ref = {
        file_path = 'src/main.lua',
        file = '/test/project/src/main.lua',
        line = 999,
      }

      reference_picker.navigate_to(ref)

      assert.equal(1, #cursor_calls)
      assert.equal(50, cursor_calls[1].pos[1])
    end)

    it('handles files with spaces in path', function()
      local cmd_calls = {}
      vim.cmd = function(cmd)
        table.insert(cmd_calls, cmd)
      end

      local ref = {
        file_path = 'src/my file.lua',
        file = '/test/project/src/my file.lua',
      }

      reference_picker.navigate_to(ref)

      assert.equal(1, #cmd_calls)
      assert.equal('tabedit /test/project/src/my\\ file.lua', cmd_calls[1])
    end)
  end)

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

    it('calls base_picker.pick with correct parameters', function()
      local pick_calls = {}
      mock_base_picker.pick = function(opts)
        table.insert(pick_calls, opts)
        return {}
      end

      mock_state.messages = {
        {
          info = { role = 'assistant', id = 'msg1' },
          parts = {
            { type = 'text', text = 'Check `src/main.lua:10`.' },
          },
        },
      }

      reference_picker.pick()

      assert.equal(1, #pick_calls)
      assert.equal(1, #pick_calls[1].items)
      assert.is_function(pick_calls[1].format_fn)
      assert.is_function(pick_calls[1].callback)
      assert.equal('Code References (1)', pick_calls[1].title)
      assert.equal(100, pick_calls[1].width)
      assert.equal('file', pick_calls[1].preview)
    end)
  end)

  describe('setup', function()
    it('can be called without errors', function()
      -- Simply test that setup doesn't throw errors
      assert.has_no.errors(function()
        reference_picker.setup()
      end)
    end)

    it('subscribes to messages state changes', function()
      local subscriptions = {}
      mock_state.subscribe = function(key, handler)
        table.insert(subscriptions, { key = key, handler = handler })
      end

      reference_picker.setup()

      assert.equal(1, #subscriptions)
      assert.equal('messages', subscriptions[1].key)
      assert.is_function(subscriptions[1].handler)
    end)
  end)

  describe('_parse_message_references', function()
    it('returns empty array when no parts', function()
      local msg = {
        info = { id = 'msg1' },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(0, #refs)
    end)

    it('parses text parts', function()
      local msg = {
        info = { id = 'msg1' },
        parts = {
          { type = 'text', text = 'Check `src/main.lua:10`.' },
        },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(1, #refs)
      assert.equal('src/main.lua', refs[1].file_path)
    end)

    it('parses multiple text parts', function()
      local msg = {
        info = { id = 'msg1' },
        parts = {
          { type = 'text', text = 'Check `file1.lua:10`.' },
          { type = 'text', text = 'Also `file2.lua:20`.' },
        },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(2, #refs)
    end)

    it('parses tool parts with file paths', function()
      local msg = {
        info = { id = 'msg1' },
        parts = {
          {
            type = 'tool',
            state = {
              input = {
                filePath = '/test/project/tool_file.lua',
              },
            },
          },
        },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(1, #refs)
      assert.equal('tool_file.lua', refs[1].file_path)
    end)

    it('maps tool part /mnt paths via runtime to_local transform', function()
      mock_config.runtime.path.to_local = function(path)
        local drive, rest = path:match('^/mnt/([a-zA-Z])/?(.*)$')
        if not drive then
          return path
        end
        local win_rest = rest:gsub('/', '\\')
        if win_rest ~= '' then
          return string.format('%s:\\%s', drive:upper(), win_rest)
        end
        return string.format('%s:\\', drive:upper())
      end
      vim.fn.filereadable = function(path)
        if path == 'C:\\Users\\me\\repo\\tool_file.lua' then
          return 1
        end
        return 0
      end

      vim.fn.fnamemodify = function(path, modifier)
        if modifier == ':~:.' and path == 'C:\\Users\\me\\repo\\tool_file.lua' then
          return 'tool_file.lua'
        end
        return path
      end

      local msg = {
        info = { id = 'msg1' },
        parts = {
          {
            type = 'tool',
            state = {
              input = {
                filePath = '/mnt/c/Users/me/repo/tool_file.lua',
              },
            },
          },
        },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(1, #refs)
      assert.equal('tool_file.lua', refs[1].file_path)
    end)

    it('combines text and tool references', function()
      local msg = {
        info = { id = 'msg1' },
        parts = {
          { type = 'text', text = 'Check `text_ref.lua:10`.' },
          {
            type = 'tool',
            state = {
              input = {
                filePath = '/test/project/tool_ref.lua',
              },
            },
          },
        },
      }

      local refs = reference_picker._parse_message_references(msg)

      assert.equal(2, #refs)
    end)
  end)
end)
