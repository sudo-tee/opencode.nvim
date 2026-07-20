local assert = require('luassert')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local Output = require('opencode.ui.output')
local state = require('opencode.state')
local util = require('opencode.util')

describe('formatter', function()
  before_each(function()
    config.setup({
      ui = {
        output = {
          compact_assistant_headers = false,
          tools = {
            show_output = true,
          },
        },
      },
    })
  end)

  it('formats multiline question answers', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_1',
      type = 'tool',
      tool = 'question',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          questions = {
            {
              question = 'What should we do?',
              header = 'Question',
              options = {},
            },
          },
        },
        metadata = {
          answers = {
            { 'First line\nSecond line' },
          },
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local output = formatter.format_part(part, message, true)
    assert.are.equal('**A1:** First line', output.lines[4])
    assert.are.equal('Second line', output.lines[5])
  end)

  it('renders task child question tools with generic summary fallback', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_1',
      type = 'tool',
      tool = 'task',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          description = 'review changes',
          subagent_type = 'explore',
        },
        metadata = {
          sessionId = 'ses_child',
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local child_parts = {
      {
        id = 'prt_child_1',
        type = 'tool',
        tool = 'question',
        messageID = 'msg_child_1',
        sessionID = 'ses_child',
        state = {
          status = 'completed',
          input = {
            questions = {
              {
                question = 'What should we do?',
                header = 'Question',
                options = {},
              },
            },
          },
          metadata = {
            answers = {
              { 'Ship it' },
            },
          },
        },
      },
    }

    local output = formatter.format_part(part, message, true, {
      interactive = true,
      get_child_parts = function(session_id)
        if session_id == 'ses_child' then
          return child_parts
        end
        return nil
      end,
    })

    assert.are.equal(' **  tool** ', output.lines[3])
  end)

  it('renders task child apply_patch tools without formatter errors', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_1',
      type = 'tool',
      tool = 'task',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          description = 'apply changes',
          subagent_type = 'coder',
        },
        metadata = {
          sessionId = 'ses_child',
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local child_parts = {
      {
        id = 'prt_child_1',
        type = 'tool',
        tool = 'apply_patch',
        messageID = 'msg_child_1',
        sessionID = 'ses_child',
        state = {
          status = 'completed',
          metadata = {
            files = {
              {
                filePath = '/tmp/project/lua/foo.lua',
              },
            },
          },
        },
      },
    }

    local output = formatter.format_part(part, message, true, {
      interactive = true,
      get_child_parts = function(session_id)
        if session_id == 'ses_child' then
          return child_parts
        end
        return nil
      end,
    })

    local found = false
    for _, line in ipairs(output.lines) do
      if line:find('apply patch', 1, true) then
        found = true
        break
      end
    end

    assert.is_true(found)
  end)

  it('renders loaded skill name for skill tool calls', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_1',
      type = 'tool',
      tool = 'skill',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          name = 'context7-cli',
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local output = formatter.format_part(part, message, true)

    assert.is_truthy(output.lines[1]:find('skill', 1, true))
    assert.is_truthy(output.lines[1]:find('context7%-cli'))
  end)

  it('renders directory reads with trailing slash', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_1',
      type = 'tool',
      tool = 'read',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          filePath = '/tmp/project',
        },
        output = '<path>/tmp/project</path>\n<type>directory</type>\n<entries>\nfoo\n</entries>',
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local output = formatter.format_part(part, message, true)
    assert.are.equal('**  read** `/tmp/project/` 1s', output.lines[1])
  end)

  it('renders diff line numbers as extmarks and targets', function()
    local output = Output.new()

    local formatter_utils = require('opencode.ui.formatter.utils')
    formatter_utils.format_diff(
      output,
      table.concat({
        'diff --git a/lua/foo.lua b/lua/foo.lua',
        'index 1111111..2222222 100644',
        '--- a/lua/foo.lua',
        '+++ b/lua/foo.lua',
        '@@ -10,3 +10,3 @@',
        '-alpha',
        ' gamma',
        '+beta',
      }, '\n'),
      'lua',
      '/test/project/lua/foo.lua'
    )

    assert.are.equal('    alpha', output.lines[3])
    assert.are.equal('    gamma', output.lines[4])
    assert.are.equal('    beta', output.lines[5])

    local delete_mark = output.extmarks[2][1]
    assert.are.equal('10', delete_mark.virt_text[1][1])
    assert.are.equal('-', delete_mark.virt_text[2][1])
    assert.are.equal('OpencodeDiffDeleteGutter', delete_mark.virt_text[1][2])

    local context_mark = output.extmarks[3][1]
    assert.are.equal('10', context_mark.virt_text[1][1])
    assert.are.equal('OpencodeDiffGutter', context_mark.virt_text[1][2])

    local add_mark = output.extmarks[4][1]
    assert.are.equal('11', add_mark.virt_text[1][1])
    assert.are.equal('+', add_mark.virt_text[2][1])
    assert.are.equal('OpencodeDiffAddGutter', add_mark.virt_text[1][2])

    assert.are.same({
      {
        kind = 'diff',
        path = '/test/project/lua/foo.lua',
        line = 10,
        range = { line = 4, start_col = 0, end_col = 9 },
      },
      {
        kind = 'diff',
        path = '/test/project/lua/foo.lua',
        line = 11,
        range = { line = 5, start_col = 0, end_col = 8 },
      },
    }, output.targets)
  end)

  it('projects supplied reference facts instead of deriving them during assistant render', function()
    local reference_parser = require('opencode.ui.reference_parser')
    local original_parse_references = reference_parser.parse_references
    reference_parser.parse_references = function()
      error('assistant render must consume reference facts, not parse assistant text')
    end

    local original_messages = state.messages
    state.renderer.set_messages(setmetatable({}, {
      __pairs = function()
        error('assistant render must not scan state.messages')
      end,
      __ipairs = function()
        error('assistant render must not scan state.messages')
      end,
    }))

    local text = 'See `src/foo.lua` now'
    local part = {
      id = 'part_render_boundary',
      type = 'text',
      text = text,
      messageID = 'msg_render_boundary',
      sessionID = 'ses_1',
    }
    local message = {
      info = { id = 'msg_render_boundary', role = 'assistant', sessionID = 'ses_1' },
      parts = { part },
    }

    local ok, err = pcall(function()
      local output = formatter.format_part(part, message, true, {
        interactive = true,
        current_files = { vim.fn.getcwd() .. '/src/foo.lua' },
        current_refs = {},
      })

      assert.are.equal(text, output.lines[1])
      assert.are.same({}, output.targets)
    end)

    reference_parser.parse_references = original_parse_references
    state.renderer.set_messages(original_messages)

    assert.is_true(ok, err)
  end)

  it('maps supplied reference facts to executable rendered file targets after trim', function()
    local reference_facts = require('opencode.ui.reference_facts')
    local icons = require('opencode.ui.icons')
    local raw_text = '  See `src/foo.lua:12:3` now  '
    local part = {
      id = 'part_trimmed_ref',
      type = 'text',
      text = raw_text,
      messageID = 'msg_trimmed_ref',
      sessionID = 'ses_1',
    }
    local message = {
      info = { id = 'msg_trimmed_ref', role = 'assistant', sessionID = 'ses_1' },
      parts = { part },
    }

    reference_facts.clear()
    reference_facts.rebuild('ses_1', { message })

    local refs = reference_facts.current_refs()
    local output = formatter.format_part(part, message, true, {
      interactive = true,
      current_refs = refs,
      current_files = { vim.fn.getcwd() .. '/src/foo.lua' },
    })
    local rendered_ref_start = output.lines[1]:find('`src/foo.lua:12:3`', 1, true) - 1
    local raw_ref_start, raw_ref_end = raw_text:find('`src/foo.lua:12:3`', 1, true)

    reference_facts.clear()

    assert.are.same({ start_offset = raw_ref_start, end_offset = raw_ref_end }, refs[1].raw_range)
    assert.are.equal('See ' .. icons.get('reference') .. '`src/foo.lua:12:3` now', output.lines[1])
    assert.are.same({
      kind = 'file',
      path = vim.fn.getcwd() .. '/src/foo.lua',
      line = 12,
      col = 3,
      range = {
        line = 1,
        start_col = rendered_ref_start,
        end_col = rendered_ref_start + #'`src/foo.lua:12:3`',
      },
    }, output.targets[1])
  end)

  it('leaves unavailable file mentions inert', function()
    local text = 'See `src/missing.lua` now'
    local ref_start, ref_end = text:find('`src/missing.lua`', 1, true)
    local part = { id = 'part_missing_ref', text = text }
    local message = { info = { id = 'msg_missing_ref' }, parts = { part } }

    local output = Output.new()
    formatter._format_assistant_message(output, text, part, message, {
      interactive = true,
      current_files = {},
      current_refs = {
        {
          message_id = 'msg_missing_ref',
          part_id = 'part_missing_ref',
          path = 'src/missing.lua',
          source_kind = 'assistant_text',
          raw_range = { start_offset = ref_start, end_offset = ref_end },
        },
      },
    })

    assert.are.equal(text, output.lines[1])
    assert.are.same({}, output.targets)
    assert.is_nil(output.extmarks[0])
  end)

  it('creates symbol targets from same-part file references before the token', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local text = 'See `src/foo.lua` foo'
    local ref_start, ref_end = text:find('`src/foo.lua`', 1, true)
    local part = { id = 'part_file_ref', text = text }
    local message = { info = { id = 'msg_file_ref' }, parts = { part } }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      targets_for_token = function(_, token, candidate_files)
        assert.are.same({ vim.fn.getcwd() .. '/src/foo.lua' }, candidate_files)
        if token == 'foo' then
          return { { token = 'foo', path = vim.fn.getcwd() .. '/src/foo.lua', line = 1, col = 1 } }
        end
        return {}
      end,
    }

    local output = Output.new()
    formatter._format_assistant_message(output, text, part, message, {
      interactive = true,
      current_files = { vim.fn.getcwd() .. '/src/foo.lua' },
      current_refs = {
        {
          message_id = 'msg_file_ref',
          part_id = 'part_file_ref',
          path = vim.fn.getcwd() .. '/src/foo.lua',
          source_kind = 'assistant_text',
          raw_range = { start_offset = ref_start, end_offset = ref_end },
        },
      },
      symbol_cycle = {},
    })

    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    local symbol_mark
    local reference_mark
    for _, mark in ipairs(output.extmarks[0]) do
      if mark.hl_group == 'OpencodeSymbolReference' then
        symbol_mark = mark
      elseif mark.hl_group == 'OpencodeReference' then
        reference_mark = mark
      end
    end
    local trailing_foo_start = output.lines[1]:find('foo$', 1, false)
    assert.are.equal(2, #output.extmarks[0])
    assert.is_not_nil(reference_mark)
    assert.is_not_nil(symbol_mark)
    assert.are.equal(trailing_foo_start - 1, symbol_mark.start_col)
    assert.are.equal(trailing_foo_start + 2, symbol_mark.end_col)
    assert.are.same({
      {
        kind = 'file',
        path = vim.fn.getcwd() .. '/src/foo.lua',
        range = output.targets[1].range,
      },
      {
        kind = 'symbol',
        token = 'foo',
        candidate_files = { vim.fn.getcwd() .. '/src/foo.lua' },
        range = { line = 1, start_col = trailing_foo_start - 1, end_col = trailing_foo_start + 2 },
      },
    }, {
      {
        kind = output.targets[1].kind,
        path = output.targets[1].path,
        range = output.targets[1].range,
      },
      output.targets[2],
    })
  end)

  it('does not create symbol targets without local candidate files', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']

    package.loaded['opencode.ui.symbol_snapshot'] = {
      targets_for_token = function()
        error('symbol lookup requires local candidate files')
      end,
    }

    local output = Output.new()
    formatter._format_assistant_message(output, 'foo bar', { id = 'part_no_candidates' }, nil, {
      interactive = true,
      current_files = { '/test/project/src/foo.lua' },
      current_refs = {},
      symbol_cycle = {},
    })

    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.are.equal('foo bar', output.lines[1])
    assert.are.same({}, output.targets)
    assert.is_nil(output.extmarks[0])
  end)

  it('uses same-message previous file refs as symbol candidates', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']

    package.loaded['opencode.ui.symbol_snapshot'] = {
      targets_for_token = function(_, token, candidate_files)
        assert.are.same({ vim.fn.getcwd() .. '/src/main.lua' }, candidate_files)
        return token == 'foo' and { { token = 'foo', path = vim.fn.getcwd() .. '/src/main.lua', line = 1, col = 1 } }
          or {}
      end,
    }

    local previous_part = { id = 'tool_1', type = 'tool' }
    local current_part = { id = 'text_1', type = 'text', text = 'foo' }
    local message = {
      info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' },
      parts = { previous_part, current_part },
    }

    local output = Output.new()
    formatter._format_assistant_message(output, 'foo', current_part, message, {
      interactive = true,
      current_files = { vim.fn.getcwd() .. '/src/main.lua' },
      current_refs = {
        {
          message_id = 'msg_1',
          part_id = 'tool_1',
          path = 'src/main.lua',
          source_kind = 'tool_file_path',
        },
      },
      symbol_cycle = {},
    })

    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    assert.are.same({
      {
        kind = 'symbol',
        token = 'foo',
        candidate_files = { vim.fn.getcwd() .. '/src/main.lua' },
        range = { line = 1, start_col = 0, end_col = 3 },
      },
    }, output.targets)
    assert.are.equal('OpencodeSymbolReference', output.extmarks[0][1].hl_group)
  end)

  it('does not highlight symbol-looking segments inside paths', function()
    local output = Output.new()
    formatter._format_assistant_message(output, 'See tests/data/symbol-reference-navigation.json and .cache/')

    assert.is_nil(output.extmarks[0])
  end)

  it('uses part identity to select assistant text reference facts', function()
    local message = {
      info = { id = 'msg_same', role = 'assistant', sessionID = 'ses_1' },
      parts = {},
    }
    local part_a = {
      id = 'part_a',
      type = 'text',
      text = 'See `a.lua`',
      messageID = 'msg_same',
      sessionID = 'ses_1',
    }
    local part_b = {
      id = 'part_b',
      type = 'text',
      text = 'See `b.lua`',
      messageID = 'msg_same',
      sessionID = 'ses_1',
    }
    local a_start, a_end = part_a.text:find('`a.lua`', 1, true)
    local b_start, b_end = part_b.text:find('`b.lua`', 1, true)
    local context = {
      current_refs = {
        {
          message_id = 'msg_same',
          part_id = 'part_a',
          path = 'a.lua',
          source_kind = 'assistant_text',
          raw_range = { start_offset = a_start, end_offset = a_end },
        },
        {
          message_id = 'msg_same',
          part_id = 'part_b',
          path = 'b.lua',
          source_kind = 'assistant_text',
          raw_range = { start_offset = b_start, end_offset = b_end },
        },
      },
    }
    local first = formatter.format_part(part_a, message, false, context)
    local second = formatter.format_part(part_b, message, true, context)

    assert.is_truthy(first.lines[1]:find('a.lua', 1, true))
    assert.is_nil(first.lines[1]:find('b.lua', 1, true))
    assert.is_truthy(second.lines[1]:find('b.lua', 1, true))
    assert.is_nil(second.lines[1]:find('a.lua', 1, true))
  end)

  it('highlights a symbol before trailing prose colon', function()
    local original_symbol_snapshot = package.loaded['opencode.ui.symbol_snapshot']
    local text = 'See `src/main.lua` foo: call this'
    local ref_start, ref_end = text:find('`src/main.lua`', 1, true)
    local part = { id = 'part_colon', text = text }
    local message = { info = { id = 'msg_colon' }, parts = { part } }
    package.loaded['opencode.ui.symbol_snapshot'] = {
      targets_for_token = function(_, token, candidate_files)
        assert.are.same({ vim.fn.getcwd() .. '/src/main.lua' }, candidate_files)
        return token == 'foo' and { { token = 'foo', path = vim.fn.getcwd() .. '/src/main.lua', line = 3, col = 1 } }
          or {}
      end,
    }

    local output = Output.new()
    formatter._format_assistant_message(output, text, part, message, {
      interactive = true,
      current_files = { vim.fn.getcwd() .. '/src/main.lua' },
      current_refs = {
        {
          message_id = 'msg_colon',
          part_id = 'part_colon',
          path = 'src/main.lua',
          source_kind = 'assistant_text',
          raw_range = { start_offset = ref_start, end_offset = ref_end },
        },
      },
      symbol_cycle = {},
    })

    package.loaded['opencode.ui.symbol_snapshot'] = original_symbol_snapshot

    local symbol_mark = output.extmarks[0][2]
    local foo_start = output.lines[1]:find('foo:', 1, true)
    assert.are.equal(text:gsub('See ', 'See ' .. require('opencode.ui.icons').get('reference'), 1), output.lines[1])
    assert.are.equal(foo_start - 1, symbol_mark.start_col)
    assert.are.equal(foo_start + 2, symbol_mark.end_col)
    assert.are.equal('foo', output.targets[2].token)
  end)

  it('formats grep tools when streamed input contains vim.NIL placeholders', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_grep_1',
      type = 'tool',
      tool = 'grep',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          path = vim.NIL,
          include = '*.lua',
          pattern = 'eventignore',
        },
        metadata = {
          matches = 3,
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local output = formatter.format_part(part, message, true)

    assert.are.equal('**  grep** `*.lua eventignore` 1s', output.lines[1])
    assert.are.equal('Found `3` matches', output.lines[2])
  end)

  it('anchors snapshot actions to the snapshot and restore lines', function()
    local snapshot = require('opencode.snapshot')
    local original_get_restore_points_by_parent = snapshot.get_restore_points_by_parent

    snapshot.get_restore_points_by_parent = function(hash)
      if hash == 'abcdef123456' then
        return {
          {
            id = 'restore123456',
            created_at = 1,
          },
        }
      end
      return {}
    end

    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_patch_1',
      type = 'patch',
      hash = 'abcdef123456',
      messageID = 'msg_1',
      sessionID = 'ses_1',
    }

    local output = formatter.format_part(part, message, true)

    snapshot.get_restore_points_by_parent = original_get_restore_points_by_parent

    assert.are.same(
      { 0, 0, 0, 1, 1 },
      vim.tbl_map(function(action)
        return action.display_line
      end, output.actions)
    )
  end)

  it('falls back to current mode for assistant messages without a stamped mode', function()
    state.model.set_mode('build')
    local output = formatter.format_message_header({
      info = {
        id = 'msg_current',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    })

    assert.are.equal('BUILD', output.extmarks[1][1].virt_text[3][1])
  end)

  it('renders minimal same-mode assistant headers with only right-aligned time', function()
    config.setup({
      ui = {
        output = {
          compact_assistant_headers = true,
        },
      },
    })

    local output = formatter.format_message_header({
      info = {
        id = 'msg_current',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
        time = {
          created = 1,
        },
      },
      parts = {},
    }, {
      info = {
        id = 'msg_prev',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
      },
      parts = {},
    })

    assert.are.same({ '', '' }, output.lines)
    assert.is_truthy(output.extmarks[0])
    assert.are.equal(util.format_time(1), output.extmarks[0][1].virt_text[1][1])
    assert.are.equal('right_align', output.extmarks[0][1].virt_text_pos)
  end)

  it('renders hidden assistant headers without any header content', function()
    config.setup({
      ui = {
        output = {
          compact_assistant_headers = 'hidden',
        },
      },
    })

    local output = formatter.format_message_header({
      info = {
        id = 'msg_current',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
        time = {
          created = 1,
        },
      },
      parts = {},
    }, {
      info = {
        id = 'msg_prev',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
      },
      parts = {},
    })

    assert.are.same({}, output.lines)
    assert.is_nil(output.extmarks[0])
  end)

  it('does not add a spacing-only block for hidden same-mode assistant messages', function()
    config.setup({
      ui = {
        output = {
          compact_assistant_headers = 'hidden',
        },
      },
    })

    local previous_message = {
      info = {
        id = 'msg_prev',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
      },
      parts = {},
    }

    local current_message = {
      info = {
        id = 'msg_current',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
      },
      parts = {},
    }

    local previous_part = formatter.format_part({
      id = 'prt_prev',
      type = 'text',
      text = 'First reply',
      messageID = 'msg_prev',
      sessionID = 'ses_1',
    }, previous_message, true)

    local header = formatter.format_message_header(current_message, previous_message)
    local current_part = formatter.format_part({
      id = 'prt_current',
      type = 'text',
      text = 'Second reply',
      messageID = 'msg_current',
      sessionID = 'ses_1',
    }, current_message, true)

    local combined_lines = {}
    vim.list_extend(combined_lines, previous_part.lines)
    vim.list_extend(combined_lines, header.lines)
    vim.list_extend(combined_lines, current_part.lines)

    assert.are.same({ 'First reply', '', 'Second reply', '' }, combined_lines)
  end)

  it('keeps full assistant headers when the mode changes', function()
    config.setup({
      ui = {
        output = {
          compact_assistant_headers = true,
        },
      },
    })

    local output = formatter.format_message_header({
      info = {
        id = 'msg_current',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'build',
        time = {
          created = 1,
        },
      },
      parts = {},
    }, {
      info = {
        id = 'msg_prev',
        role = 'assistant',
        sessionID = 'ses_1',
        mode = 'plan',
      },
      parts = {},
    })

    assert.are.same({ '----', '', '' }, output.lines)
    assert.are.equal('BUILD', output.extmarks[1][1].virt_text[3][1])
  end)

  it('anchors task child-session action to the rendered task block', function()
    local message = {
      info = {
        id = 'msg_1',
        role = 'assistant',
        sessionID = 'ses_1',
      },
      parts = {},
    }

    local part = {
      id = 'prt_task_1',
      type = 'tool',
      tool = 'task',
      messageID = 'msg_1',
      sessionID = 'ses_1',
      state = {
        status = 'completed',
        input = {
          description = 'review changes',
          subagent_type = 'explore',
        },
        metadata = {
          sessionId = 'ses_child',
        },
        time = {
          start = 1,
          ['end'] = 2,
        },
      },
    }

    local child_parts = {
      {
        id = 'prt_child_1',
        type = 'tool',
        tool = 'read',
        messageID = 'msg_child_1',
        sessionID = 'ses_child',
        state = {
          status = 'completed',
          input = {
            filePath = '/tmp/project',
          },
        },
      },
    }

    local output = formatter.format_part(part, message, true, {
      interactive = true,
      get_child_parts = function(session_id)
        if session_id == 'ses_child' then
          return child_parts
        end
        return nil
      end,
    })

    assert.are.same({
      text = '[S] Open this Session',
      type = 'navigate_session_tree',
      args = { 'ses_child' },
      key = 'S',
      display_line = 1,
      range = { from = 2, to = 5 },
    }, output.actions[1])
    assert.is_truthy(table.concat(output.lines, '\n'):find('read', 1, true))
  end)

  describe('fold_exclude', function()
    local function make_bash_part()
      return {
        id = 'prt_bash',
        type = 'tool',
        tool = 'bash',
        messageID = 'msg_1',
        sessionID = 'ses_1',
        state = {
          status = 'completed',
          input = {
            command = 'echo hello',
          },
          metadata = {
            output = 'hello\nworld\nfoo\nbar\nbaz\nqux',
          },
          time = { start = 1, ['end'] = 2 },
        },
      }
    end

    local function make_mcp_part()
      return {
        id = 'prt_mcp',
        type = 'tool',
        tool = 'sequential-thinking_sequentialthinking',
        messageID = 'msg_1',
        sessionID = 'ses_1',
        state = {
          status = 'completed',
          input = { thought = 'thinking...' },
          metadata = {},
          time = { start = 1, ['end'] = 2 },
        },
      }
    end

    it('removes folds for built-in tools matched by string', function()
      config.setup({
        ui = {
          output = {
            tools = {
              use_folds = true,
              folding_threshold = 5,
              fold_exclude = { 'bash' },
            },
          },
        },
      })

      local message = { info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' }, parts = {} }
      local output = formatter.format_part(make_bash_part(), message, true)
      assert.are.same({}, output.fold_ranges)
    end)

    it('removes folds for MCP tools matched by server+tool table', function()
      config.setup({
        ui = {
          output = {
            tools = {
              use_folds = true,
              folding_threshold = 5,
              fold_exclude = { { server = 'sequential-thinking', tool = 'sequentialthinking' } },
            },
          },
        },
      })

      local message = { info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' }, parts = {} }
      local output = formatter.format_part(make_mcp_part(), message, true)
      assert.are.same({}, output.fold_ranges)
      -- Verify thought content is rendered
      local found = false
      for _, line in ipairs(output.lines) do
        if line:find('thinking') then
          found = true
          break
        end
      end
      assert.is_true(found, 'MCP formatter should render thought content')
    end)

    it('keeps folds for tools not in fold_exclude', function()
      config.setup({
        ui = {
          output = {
            tools = {
              use_folds = true,
              folding_threshold = 5,
              fold_exclude = { 'grep' },
            },
          },
        },
      })

      local message = { info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' }, parts = {} }
      local output = formatter.format_part(make_bash_part(), message, true)
      assert.is_true(#output.fold_ranges > 0)
    end)

    it('keeps folds when fold_exclude is empty', function()
      config.setup({
        ui = {
          output = {
            tools = {
              use_folds = true,
              folding_threshold = 5,
              fold_exclude = {},
            },
          },
        },
      })

      local message = { info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' }, parts = {} }
      local output = formatter.format_part(make_bash_part(), message, true)
      assert.is_true(#output.fold_ranges > 0)
    end)

    describe('message actions', function()
      it('does not assign R/C/F to an individual user text part', function()
        local message = { info = { id = 'msg-user', role = 'user' }, parts = {} }
        local output = formatter.format_part({ type = 'text', text = 'first\nsecond' }, message, true, {})

        assert.same({ 'first', 'second', '' }, output.lines)
        assert.same({}, output.actions)
      end)
    end)
  end)
end)
