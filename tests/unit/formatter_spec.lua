local assert = require('luassert')
local config = require('opencode.config')
local formatter = require('opencode.ui.formatter')

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
end)
