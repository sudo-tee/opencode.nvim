local question_window = require('opencode.ui.question_window')
local Output = require('opencode.ui.output')

describe('question_window', function()
  after_each(function()
    question_window._current_question = nil
    question_window._current_question_index = 1
    question_window._collected_answers = {}
    question_window._answering = false
    question_window._dialog = nil
  end)

  it('extends the question border through the trailing spacer line', function()
    local captured_opts = nil
    question_window._current_question = {
      id = 'q1',
      questions = {
        {
          question = 'How should tests run?',
          options = {
            { label = 'On save', description = 'Run tests automatically' },
          },
        },
      },
    }
    question_window._dialog = {
      format_dialog = function(_, _, opts)
        captured_opts = opts
      end,
    }

    question_window.format_display(Output.new())

    assert.is_not_nil(captured_opts)
    assert.is_true(captured_opts.extend_border_to_trailing_blank)
    assert.are.equal('On save', captured_opts.options[1].label)
    assert.are.equal('Other', captured_opts.options[2].label)
  end)
end)
