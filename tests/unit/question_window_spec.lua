local question_window = require('opencode.ui.question_window')
local Output = require('opencode.ui.output')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local stub = require('luassert.stub')

describe('question_window', function()
  after_each(function()
    question_window._current_question = nil
    question_window._current_question_index = 1
    question_window._collected_answers = {}
    question_window._answering = false
    question_window._dialog = nil
    state.renderer.set_messages({})
    state.session.set_active(nil)
    state.jobs.set_api_client(nil)
  end)

  it('adds the Other option when missing', function()
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
    assert.are.equal('On save', captured_opts.options[1].label)
    assert.are.equal('Other', captured_opts.options[2].label)
  end)

  it('does not show a question that is already completed', function()
    state.renderer.set_messages({
      {
        info = {
          id = 'msg_question',
          sessionID = 'sess1',
        },
        parts = {
          {
            id = 'part_question',
            type = 'tool',
            tool = 'question',
            callID = 'call_question',
            messageID = 'msg_question',
            sessionID = 'sess1',
            state = {
              status = 'completed',
              metadata = {
                answers = {
                  { 'Red' },
                },
              },
            },
          },
        },
      },
    })

    question_window.show_question({
      id = 'question_1',
      sessionID = 'sess1',
      tool = {
        messageID = 'msg_question',
        callID = 'call_question',
      },
      questions = {
        {
          question = 'Pick one',
          options = {
            { label = 'One', description = 'first' },
          },
        },
      },
    })

    assert.is_nil(question_window._current_question)
  end)

  it('clears a stale completed question instead of restoring it again', function()
    local request = {
      id = 'question_1',
      sessionID = 'sess1',
      tool = {
        messageID = 'msg_question',
        callID = 'call_question',
      },
      questions = {
        {
          question = 'Pick one',
          options = {
            { label = 'One', description = 'first' },
          },
        },
      },
    }

    state.session.set_active({ id = 'sess1' })
    state.renderer.set_messages({
      {
        info = {
          id = 'msg_question',
          sessionID = 'sess1',
        },
        parts = {
          {
            id = 'part_question',
            type = 'tool',
            tool = 'question',
            callID = 'call_question',
            messageID = 'msg_question',
            sessionID = 'sess1',
            state = {
              status = 'completed',
              metadata = {
                answers = {
                  { 'Red' },
                },
              },
            },
          },
        },
      },
    })
    question_window._current_question = request
    state.jobs.set_api_client({
      list_questions = function()
        return Promise.new():resolve({ request })
      end,
    })

    local show_stub = stub(question_window, 'show_question')

    question_window.restore_pending_question('sess1'):wait()

    assert.is_nil(question_window._current_question)
    assert.stub(show_stub).was_not_called()

    show_stub:revert()
  end)
end)
