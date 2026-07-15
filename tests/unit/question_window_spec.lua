local question_window = require('opencode.ui.question_window')
local Output = require('opencode.ui.output')
local Promise = require('opencode.promise')
local state = require('opencode.state')
local config = require('opencode.config')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')

describe('question_window', function()
  local original_use_vim_ui_select
  local original_inline_other_input

  before_each(function()
    original_use_vim_ui_select = config.ui.questions.use_vim_ui_select
    original_inline_other_input = config.ui.questions.inline_other_input
  end)

  after_each(function()
    config.ui.questions.use_vim_ui_select = original_use_vim_ui_select
    config.ui.questions.inline_other_input = original_inline_other_input
    question_window._clear_inline_input()
    question_window._current_question = nil
    question_window._current_question_index = 1
    question_window._collected_answers = {}
    question_window._multi_selections = {}
    question_window._answering = false
    question_window._empty_confirm_armed = false
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

  it('uses each question multiple field when navigating between questions', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window.show_question({
      id = 'q-mode-switch',
      sessionID = 'sess1',
      questions = {
        {
          question = 'Pick many',
          multiple = true,
          custom = false,
          options = { { label = 'One' } },
        },
        {
          question = 'Pick one',
          multiple = false,
          custom = false,
          options = { { label = 'Two' } },
        },
      },
    })

    assert.is_true(question_window._dialog._is_multiple)

    question_window._dialog:navigate_group(1)
    assert.are.equal(2, question_window._current_question_index)
    assert.is_false(question_window._dialog._is_multiple)

    question_window._dialog:navigate_group(-1)
    assert.are.equal(1, question_window._current_question_index)
    assert.is_true(question_window._dialog._is_multiple)

    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('requires two Enter presses to submit an empty multi-select answer', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
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
      id = 'q-empty-multi',
      sessionID = 'sess1',
      questions = {
        {
          question = 'Pick any',
          multiple = true,
          custom = false,
          options = { { label = 'One' } },
        },
      },
    })

    question_window._dialog:set_selection(1)
    question_window._dialog:select()
    assert.are.equal(0, #replies)
    assert.is_true(question_window._multi_selections[1][1])

    question_window._dialog:select()
    assert.is_nil(question_window._multi_selections[1][1])

    question_window._dialog:set_selection(2)
    question_window._dialog:select()

    assert.are.equal(0, #replies)
    assert.is_true(question_window._empty_confirm_armed)
    local output = Output.new()
    question_window.format_display(output)
    assert.is_truthy(
      table.concat(output.lines, '\n'):find('Confirm empty answer %- Press Enter again to submit no selections')
    )

    question_window._dialog:navigate(-1)
    assert.is_false(question_window._empty_confirm_armed)

    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    assert.are.equal(0, #replies)
    assert.is_true(question_window._empty_confirm_armed)

    question_window._dialog:select()

    assert.is_true(vim.wait(200, function()
      return #replies == 1
    end))
    assert.are.same({ {} }, replies[1].answers)
    assert.is_nil(question_window._current_question)
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('hides custom input when custom is false', function()
    local captured_opts = nil
    question_window._current_question = {
      id = 'q-no-custom',
      questions = {
        {
          question = 'Pick one',
          custom = false,
          options = { { label = 'One' } },
        },
      },
    }
    question_window._dialog = {
      format_dialog = function(_, _, opts)
        captured_opts = opts
      end,
    }

    question_window.format_display(Output.new())

    assert.are.equal(1, #captured_opts.options)
    assert.are.equal('One', captured_opts.options[1].label)
  end)

  it('submits a normal Other option by its label', function()
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
    question_window._current_question = {
      id = 'q-normal-other',
      questions = {
        {
          question = 'Pick one',
          custom = false,
          options = { { label = 'Other choice' } },
        },
      },
    }
    question_window._dialog = {
      teardown = function() end,
    }

    question_window._answer_with_option(1)

    assert.are.same({ { 'Other choice' } }, replies[1].answers)
  end)

  it('uses the vim.ui.select index for a custom option with a duplicate label', function()
    question_window._current_question = {
      id = 'q-duplicate-other',
      questions = {
        {
          question = 'Pick one',
          options = { { label = 'Other' } },
        },
      },
    }

    local original_select = vim.ui.select
    vim.ui.select = function(_, _, on_choice)
      on_choice('Other', 2)
    end
    local answer_stub = stub(question_window, '_answer_with_option')

    question_window._show_question_with_vim_ui_select()

    vim.ui.select = original_select
    assert.stub(answer_stub).was_called_with(2, 'q-duplicate-other', 1)
    answer_stub:revert()
  end)

  it('submits a single custom answer and keeps a multi custom answer as a draft', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

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

    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end

    question_window.show_question({
      id = 'q-single-custom',
      sessionID = 'sess1',
      questions = {
        { question = 'Pick one', options = { { label = 'One' } } },
      },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    assert.is_true(vim.wait(200, function()
      return input_callback ~= nil
    end))
    input_callback('single custom')

    assert.are.same({ { 'single custom' } }, replies[1].answers)

    input_callback = nil
    question_window.show_question({
      id = 'q-multi-custom',
      sessionID = 'sess1',
      questions = {
        { question = 'Pick many', multiple = true, options = { { label = 'One' } } },
      },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    input_callback('multi custom')

    assert.are.equal(1, #replies)
    assert.are.equal('multi custom', question_window._multi_selections[1].custom_answer)

    question_window._dialog:select()
    assert.is_nil(question_window._multi_selections[1].custom_answer)

    question_window._dialog:select()
    input_callback('multi custom')
    question_window._dialog:set_selection(3)
    question_window._dialog:select()
    assert.is_true(vim.wait(200, function()
      return #replies == 2
    end))
    assert.are.same({ { 'multi custom' } }, replies[2].answers)

    vim.ui.input = original_input
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('routes synchronous question actions through the current question mode', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = 0
    local rejections = 0
    state.jobs.set_api_client({
      reply_question = function()
        replies = replies + 1
        return Promise.new():resolve({})
      end,
      reject_question = function()
        rejections = rejections + 1
        return Promise.new():resolve({})
      end,
    })
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end
    local actions = require('opencode.commands.handlers.permission').actions

    question_window.show_question({
      id = 'q-command-multi',
      sessionID = 'sess1',
      questions = { { question = 'Pick many', multiple = true, options = { { label = 'One' } } } },
    })
    actions.question_answer()
    assert.is_true(question_window._multi_selections[1][1])
    assert.are.equal(0, replies)

    actions.question_other()
    input_callback('custom')
    assert.are.equal('custom', question_window._multi_selections[1].custom_answer)
    assert.are.equal(0, replies)

    question_window.show_question({
      id = 'q-command-no-custom',
      sessionID = 'sess1',
      questions = { { question = 'Pick many', multiple = true, custom = false, options = { { label = 'One' } } } },
    })
    input_callback = nil
    actions.question_other()

    assert.is_nil(input_callback)
    assert.are.equal(0, replies)
    assert.are.equal(0, rejections)

    vim.ui.input = original_input
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('releases inline editors when questions are replaced or cleared', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)

    local function open_multi_other(id)
      question_window.show_question({
        id = id,
        sessionID = 'sess1',
        questions = { { question = 'Pick many', multiple = true, options = { { label = 'One' } } } },
      })
      require('opencode.ui.renderer.flush').flush()
      question_window._dialog:set_selection(2)
      question_window._dialog:select()
      assert.is_not_nil(question_window._inline_input)
      return question_window._inline_input
    end

    local replaced = open_multi_other('q-inline-replaced')
    question_window.show_question({
      id = 'q2',
      sessionID = 'sess1',
      questions = { { question = 'Current', multiple = true, options = { { label = 'Two' } } } },
    })

    assert.is_false(vim.api.nvim_win_is_valid(replaced.win))
    assert.is_nil(question_window._inline_input)
    assert.is_true(question_window._dialog:is_active())
    assert.are.equal('q2', question_window._current_question.id)

    local cleared = open_multi_other('q-inline-cleared')
    question_window.clear_question()

    assert.is_false(vim.api.nvim_win_is_valid(cleared.win))
    assert.is_nil(question_window._inline_input)
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('releases Dialog resources before switching to vim.ui.select', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    question_window.show_question({
      id = 'q-dialog',
      sessionID = 'sess1',
      questions = { { question = 'Pick one', options = { { label = 'One' } } } },
    })
    local old_dialog = question_window._dialog
    local flush = require('opencode.ui.renderer.flush')
    flush.flush()

    config.ui.questions.use_vim_ui_select = true
    local original_select = vim.ui.select
    vim.ui.select = function() end
    question_window.show_question({
      id = 'q-selector',
      sessionID = 'sess1',
      questions = { { question = 'Pick one', options = { { label = 'Two' } } } },
    })
    flush.flush()

    assert.is_false(old_dialog:is_active())
    local has_dialog_tab = false
    for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(state.windows.output_buf, 'n')) do
      if keymap.lhs == '<Tab>' then
        has_dialog_tab = true
      end
    end
    assert.is_false(has_dialog_tab)
    assert.is_nil(require('opencode.ui.renderer.ctx').render_state:get_part('question-display-part'))

    vim.ui.select = original_select
    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('keeps the question open when a custom editor is cancelled', function()
    local replies = 0
    local rejections = 0
    state.jobs.set_api_client({
      reply_question = function()
        replies = replies + 1
        return Promise.new():resolve({})
      end,
      reject_question = function()
        rejections = rejections + 1
        return Promise.new():resolve({})
      end,
    })
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end
    question_window._current_question = {
      id = 'q-custom-cancel',
      questions = {
        { question = 'Pick one', options = { { label = 'One' } } },
      },
    }

    question_window._answer_with_custom()
    input_callback(nil)

    assert.are.equal(0, replies)
    assert.are.equal(0, rejections)
    assert.are.equal('q-custom-cancel', question_window._current_question.id)
    vim.ui.input = original_input
  end)

  it('restores the triggering backend when a selected custom answer is cancelled', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = 0
    local rejections = 0
    state.jobs.set_api_client({
      reply_question = function()
        replies = replies + 1
        return Promise.new():resolve({})
      end,
      reject_question = function()
        rejections = rejections + 1
        return Promise.new():resolve({})
      end,
    })
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end

    question_window.show_question({
      id = 'q-dialog-custom-cancel',
      sessionID = 'sess1',
      questions = { { question = 'Pick one', options = { { label = 'One' } } } },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    assert.is_true(vim.wait(200, function()
      return input_callback ~= nil
    end))
    input_callback(nil)

    assert.is_false(question_window._answering)
    assert.is_true(question_window._dialog:is_active())
    assert.are.equal(0, replies)
    assert.are.equal(0, rejections)

    local original_select = vim.ui.select
    local callbacks = {}
    vim.ui.select = function(_, _, callback)
      table.insert(callbacks, callback)
    end
    config.ui.questions.use_vim_ui_select = true
    input_callback = nil
    question_window.show_question({
      id = 'q-select-custom-cancel',
      questions = { { question = 'Pick one', options = { { label = 'One' } } } },
    })
    callbacks[1]('Other', 2)
    input_callback(nil)

    assert.is_false(question_window._answering)
    assert.are.equal(2, #callbacks)
    assert.are.equal(0, replies)
    assert.are.equal(0, rejections)

    callbacks[2]('One', 1)
    assert.are.equal(1, replies)

    vim.ui.input = original_input
    vim.ui.select = original_select
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('uses vim.ui.select for every single question and Dialog for mixed requests', function()
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
    config.ui.questions.use_vim_ui_select = true

    local original_select = vim.ui.select
    local callbacks = {}
    vim.ui.select = function(_, _, callback)
      table.insert(callbacks, callback)
    end

    question_window.show_question({
      id = 'q-all-single',
      questions = {
        { question = 'First', options = { { label = 'One' } } },
        { question = 'Second', options = { { label = 'Two' } } },
      },
    })
    assert.are.equal(1, #callbacks)
    callbacks[1]('One', 1)
    assert.are.equal(2, #callbacks)
    callbacks[2]('Two', 1)
    assert.are.same({ { 'One' }, { 'Two' } }, replies[1].answers)

    vim.ui.select = original_select

    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    question_window.show_question({
      id = 'q-mixed',
      sessionID = 'sess1',
      questions = {
        { question = 'First', options = { { label = 'One' } } },
        { question = 'Second', multiple = true, options = { { label = 'Two' } } },
      },
    })

    local flush = require('opencode.ui.renderer.flush')
    flush.flush()
    assert.is_not_nil(question_window._dialog)
    assert.is_not_nil(require('opencode.ui.renderer.ctx').render_state:get_part('question-display-part'))

    question_window.clear_question()
    flush.flush()
    assert.is_nil(require('opencode.ui.renderer.ctx').render_state:get_part('question-display-part'))
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('ignores callbacks after another request replaces their question', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = {}
    local rejections = {}
    state.jobs.set_api_client({
      reply_question = function(_, request_id, answers)
        table.insert(replies, { request_id = request_id, answers = answers })
        return Promise.new():resolve({})
      end,
      reject_question = function(_, request_id)
        table.insert(rejections, request_id)
        return Promise.new():resolve({})
      end,
    })

    local function replace_with_q2()
      question_window.show_question({
        id = 'q2',
        sessionID = 'sess1',
        questions = {
          { question = 'Current', multiple = true, options = { { label = 'Two' } } },
        },
      })
    end

    question_window.show_question({
      id = 'q1-option',
      sessionID = 'sess1',
      questions = { { question = 'Old', custom = false, options = { { label = 'One' } } } },
    })
    question_window._dialog:select()
    replace_with_q2()
    vim.wait(200)

    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end
    question_window.show_question({
      id = 'q1-custom',
      sessionID = 'sess1',
      questions = { { question = 'Old', options = { { label = 'One' } } } },
    })
    question_window._answer_with_custom()
    replace_with_q2()
    input_callback('stale custom')

    question_window.show_question({
      id = 'q1-multi',
      sessionID = 'sess1',
      questions = { { question = 'Old', multiple = true, options = { { label = 'One' } } } },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    replace_with_q2()
    input_callback('stale multi custom')

    question_window.show_question({
      id = 'q1-submit',
      sessionID = 'sess1',
      questions = { { question = 'Old', multiple = true, custom = false, options = { { label = 'One' } } } },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    replace_with_q2()
    vim.wait(200)

    config.ui.questions.use_vim_ui_select = true
    local original_select = vim.ui.select
    local select_callback
    vim.ui.select = function(_, _, callback)
      select_callback = callback
    end
    question_window.show_question({
      id = 'q1-select',
      sessionID = 'sess1',
      questions = { { question = 'Old', options = { { label = 'One' } } } },
    })
    replace_with_q2()
    select_callback(nil)

    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)
    assert.are.equal('q2', question_window._current_question.id)
    assert.is_false(question_window._answering)
    assert.is_true(question_window._dialog:is_active())
    assert.is_nil(question_window._multi_selections[1])

    vim.ui.input = original_input
    vim.ui.select = original_select
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('keeps separate custom drafts for each question and clears them for a new request', function()
    helpers.replay_setup()
    state.session.set_active({ id = 'sess1' })
    vim.api.nvim_set_current_win(state.windows.output_win)
    local flush = require('opencode.ui.renderer.flush')

    local function open_other()
      flush.flush()
      assert.is_not_nil(require('opencode.ui.renderer.ctx').render_state:get_part('question-display-part'))
      assert.is_not_nil(question_window._dialog:get_option_position(2))
      question_window._dialog:set_selection(2)
      question_window._dialog:select()
      local input = question_window._inline_input
      assert.is_not_nil(input)
      vim.api.nvim_set_current_win(input.win)
      return input.buf
    end

    local function leave_other(text)
      local buf = open_other()
      vim.api.nvim_buf_set_lines(buf, 0, 1, false, { text })
      vim.api.nvim_set_current_win(state.windows.output_win)
    end

    local function read_other()
      local buf = open_other()
      return vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
    end

    question_window.show_question({
      id = 'multi-question',
      sessionID = 'sess1',
      questions = {
        {
          header = 'First',
          question = 'First custom answer',
          options = { { label = 'One' } },
        },
        {
          header = 'Second',
          question = 'Second custom answer',
          options = { { label = 'Two' } },
        },
      },
    })

    leave_other('draft for first question')
    question_window._dialog:navigate_group(1)
    leave_other('draft for second question')

    question_window._dialog:navigate_group(-1)
    local first_draft = read_other()
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window._dialog:navigate_group(1)
    local second_draft = read_other()
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window.show_question({
      id = 'new-request',
      sessionID = 'sess1',
      questions = {
        {
          question = 'New custom answer',
          options = { { label = 'Three' } },
        },
      },
    })
    local new_request_draft = read_other()

    vim.api.nvim_set_current_win(state.windows.output_win)
    question_window.clear_question()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end

    assert.equals('draft for first question', first_draft)
    assert.equals('draft for second question', second_draft)
    assert.equals('', new_request_draft)
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
