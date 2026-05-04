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

    local output = formatter.format_part(part, message, true, function(session_id)
      if session_id == 'ses_child' then
        return child_parts
      end
      return nil
    end)

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

    local output = formatter.format_part(part, message, true, function(session_id)
      if session_id == 'ses_child' then
        return child_parts
      end
      return nil
    end)

    local found = false
    for _, line in ipairs(output.lines) do
      if line:find('apply patch', 1, true) then
        found = true
        break
      end
    end

    assert.is_true(found)
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

  it('renders diff line numbers as extmarks', function()
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
      'lua'
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

    local output = formatter.format_part(part, message, true, function(session_id)
      if session_id == 'ses_child' then
        return child_parts
      end
      return nil
    end)

    assert.are.same({
      text = '[S]elect Child Session',
      type = 'navigate_session_tree',
      args = { 'child', 'picker' },
      key = 'S',
      display_line = 1,
      range = { from = 2, to = 5 },
    }, output.actions[1])
  end)
end)
