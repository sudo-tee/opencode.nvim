local assert = require('luassert')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')
local Output = require('opencode.ui.output')

describe('formatter', function()
  before_each(function()
    config.setup({
      ui = {
        output = {
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
end)
