local question_window = require('opencode.ui.question_window')
local Output = require('opencode.ui.output')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')

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

  it('tracks answers by question index and waits until all are answered', function()
    local replies = {}

    state.jobs.set_api_client({
      reply_question = function(_, request_id, answers)
        table.insert(replies, { request_id = request_id, answers = answers })
        return Promise.new():resolve({})
      end,
      reject_question = function()
        return Promise.new():resolve({})
      end,
    })

    question_window.show_question({
      id = 'q-multi',
      sessionID = 'sess1',
      questions = {
        {
          header = 'First',
          question = 'Pick first',
          options = {
            { label = 'One' },
          },
        },
        {
          header = 'Second',
          question = 'Pick second',
          options = {
            { label = 'Two' },
          },
        },
      },
    })

    question_window._current_question_index = 2
    question_window._answer_with_option(1)

    assert.are.same({ { 'Two' } }, { question_window._collected_answers[2] })
    assert.are.equal(1, question_window._current_question_index)
    assert.are.equal(0, #replies)

    question_window._answer_with_option(1)

    assert.are.equal(1, #replies)
    assert.are.same({ { 'One' }, { 'Two' } }, replies[1].answers)
    assert.is_nil(question_window._current_question)
  end)

  it('renders multi-question tabs with answer status', function()
    local output = Output.new()

    question_window._current_question = {
      id = 'q1',
      questions = {
        {
          header = 'Color',
          question = 'Pick a color',
          options = {
            { label = 'Blue', description = 'cool' },
          },
        },
        {
          header = 'Shape',
          question = 'Pick a shape',
          options = {
            { label = 'Circle', description = 'round' },
          },
        },
      },
    }
    question_window._current_question_index = 2
    question_window._collected_answers = {
      [1] = { 'Blue' },
    }
    question_window._dialog = {
      format_dialog = function(_, _, opts)
        output:add_line(opts.title)
      end,
    }

    question_window.format_display(output)

    assert.are.equal(' 1 [Color] 󰄳    2 [Shape]   ', output.lines[1])

    assert.are.equal('OpencodeQuestionTabDone', output.extmarks[0][1].hl_group)
    assert.are.equal('OpencodeQuestionTabActive', output.extmarks[0][2].hl_group)
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

  it('does not force-scroll on question navigation redraws', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)

    local renderer = require('opencode.ui.renderer')
    local output_window = require('opencode.ui.output_window')

    local lines = {}
    for i = 1, 40 do
      lines[i] = 'line ' .. i
    end
    output_window.set_lines(lines)
    vim.api.nvim_win_set_cursor(state.windows.output_win, { 5, 0 })
    output_window.sync_cursor_with_viewport(state.windows.output_win)

    question_window.show_question({
      id = 'q-nav',
      sessionID = 'sess1',
      questions = {
        {
          question = 'Pick one',
          options = {
            { label = 'One' },
            { label = 'Two' },
          },
        },
      },
    })

    local flush = require('opencode.ui.renderer.flush')
    flush.flush()
    output_window.sync_cursor_with_viewport(state.windows.output_win)

    local before = vim.api.nvim_win_get_cursor(state.windows.output_win)
    question_window._dialog:navigate(1)
    flush.flush()

    local after = vim.api.nvim_win_get_cursor(state.windows.output_win)
    assert.equals(before[1], after[1])
    assert.equals(before[2], after[2])

    question_window.clear_question()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('navigates between questions with h and l', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window.show_question({
      id = 'q-nav-groups',
      sessionID = 'sess1',
      questions = {
        {
          header = 'First',
          question = 'Pick one',
          options = {
            { label = 'One' },
          },
        },
        {
          header = 'Second',
          question = 'Pick two',
          options = {
            { label = 'Two' },
          },
        },
      },
    })

    question_window._dialog:navigate_group(1)
    assert.are.equal(2, question_window._current_question_index)

    question_window._dialog:navigate_group(-1)
    assert.are.equal(1, question_window._current_question_index)

    question_window.clear_question()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)
end)
