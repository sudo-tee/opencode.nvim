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
  local focus_stub

  local function bind_observation(replies, rejections)
    local observation = {
      reply_question = function(_, request_id, answers)
        replies[#replies + 1] = { request_id = request_id, answers = answers }
        return Promise.new():resolve(true)
      end,
      reject_question = function(_, request_id)
        rejections[#rejections + 1] = request_id
        return Promise.new():resolve(true)
      end,
    }
    question_window._observations = setmetatable({}, {
      __index = function()
        return observation
      end,
    })
  end

  before_each(function()
    original_use_vim_ui_select = config.ui.questions.use_vim_ui_select
    original_inline_other_input = config.ui.questions.inline_other_input
    focus_stub = stub(require('opencode.ui.ui'), 'is_opencode_focused').returns(true)
  end)

  after_each(function()
    config.ui.questions.use_vim_ui_select = original_use_vim_ui_select
    config.ui.questions.inline_other_input = original_inline_other_input
    question_window._clear_inline_input()
    if question_window._dialog and question_window._dialog.teardown then
      question_window._clear_dialog()
    else
      question_window._dialog = nil
    end
    question_window._current_question = nil
    question_window._current_question_index = 1
    question_window._collected_answers = {}
    question_window._multi_selections = {}
    question_window._answering = false
    question_window._empty_confirm_armed = false
    question_window._observations = {}
    state.session.set_active(nil)
    focus_stub:revert()
  end)

  it('tracks answers by question index and waits until all are answered', function()
    local replies = {}
    bind_observation(replies, {})

    question_window.show_question({
      id = 'q-multi',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          key = 'first',
          title = 'First',
          prompt = 'Pick first',
          type = 'string',
          options = {
            { label = 'One' },
          },
        },
        {
          key = 'second',
          title = 'Second',
          prompt = 'Pick second',
          type = 'string',
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
    assert.are.same({ first = 'One', second = 'Two' }, replies[1].answers)
    assert.is_nil(question_window._current_question)
  end)

  it('renders multi-question tabs with answer status', function()
    local output = Output.new()

    question_window._current_question = {
      id = 'q1',
      fields = {
        {
          title = 'Color',
          prompt = 'Pick a color',
          options = {
            { label = 'Blue', description = 'cool' },
          },
        },
        {
          title = 'Shape',
          prompt = 'Pick a shape',
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
      fields = {
        {
          prompt = 'How should tests run?',
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
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window.show_question({
      id = 'q-mode-switch',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          prompt = 'Pick many',
          type = 'multiselect',
          custom = false,
          options = { { label = 'One' } },
        },
        {
          prompt = 'Pick one',
          type = 'string',
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
    vim.api.nvim_set_current_win(state.windows.output_win)
    local replies = {}
    bind_observation(replies, {})

    question_window.show_question({
      id = 'q-empty-multi',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          key = 'choices',
          prompt = 'Pick any',
          type = 'multiselect',
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
    assert.are.same({ choices = {} }, replies[1].answers)
    assert.is_nil(question_window._current_question)
    require('opencode.ui.ui').close_windows(state.windows)
  end)

  it('hides custom input when custom is false', function()
    local captured_opts = nil
    question_window._current_question = {
      id = 'q-no-custom',
      fields = {
        {
          prompt = 'Pick one',
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
    bind_observation(replies, {})
    question_window._current_question = {
      id = 'q-normal-other',
      fields = {
        {
          key = 'choice',
          prompt = 'Pick one',
          type = 'string',
          custom = false,
          options = { { label = 'Other choice' } },
        },
      },
    }
    question_window._dialog = {
      teardown = function() end,
    }

    question_window._answer_with_option(1)

    assert.are.same({ choice = 'Other choice' }, replies[1].answers)
  end)

  it('uses the vim.ui.select index for a custom option with a duplicate label', function()
    question_window._current_question = {
      id = 'q-duplicate-other',
      fields = {
        {
          prompt = 'Pick one',
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
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = {}
    bind_observation(replies, {})

    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end

    question_window.show_question({
      id = 'q-single-custom',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        { key = 'choice', prompt = 'Pick one', type = 'string', options = { { label = 'One' } } },
      },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    assert.is_true(vim.wait(200, function()
      return input_callback ~= nil
    end))
    input_callback('single custom')

    assert.are.same({ choice = 'single custom' }, replies[1].answers)

    input_callback = nil
    question_window.show_question({
      id = 'q-multi-custom',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        { key = 'choices', prompt = 'Pick many', type = 'multiselect', options = { { label = 'One' } } },
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
    assert.are.same({ choices = { 'multi custom' } }, replies[2].answers)

    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
    vim.ui.input = original_input
  end)

  it('routes synchronous question actions through the current question mode', function()
    helpers.replay_setup()
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = {}
    local rejections = {}
    bind_observation(replies, rejections)
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end
    local actions = require('opencode.commands.handlers.permission').actions

    question_window.show_question({
      id = 'q-command-multi',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Pick many', type = 'multiselect', options = { { label = 'One' } } } },
    })
    actions.question_answer()
    assert.is_true(question_window._multi_selections[1][1])
    assert.are.equal(0, #replies)

    actions.question_other()
    input_callback('custom')
    assert.are.equal('custom', question_window._multi_selections[1].custom_answer)
    assert.are.equal(0, #replies)

    question_window.show_question({
      id = 'q-command-no-custom',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Pick many', type = 'multiselect', custom = false, options = { { label = 'One' } } } },
    })
    input_callback = nil
    actions.question_other()

    assert.is_nil(input_callback)
    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)

    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
    vim.ui.input = original_input
  end)

  it('releases inline editors when questions are replaced or cleared', function()
    helpers.replay_setup()
    vim.api.nvim_set_current_win(state.windows.output_win)

    local function open_multi_other(id)
      question_window.show_question({
        id = id,
        status = 'pending',
        session_id = 'sess1',
        fields = { { prompt = 'Pick many', type = 'multiselect', options = { { label = 'One' } } } },
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
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Current', type = 'multiselect', options = { { label = 'Two' } } } },
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
    vim.api.nvim_set_current_win(state.windows.output_win)
    question_window.show_question({
      id = 'q-dialog',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Pick one', options = { { label = 'One' } } } },
    })
    local old_dialog = question_window._dialog
    local flush = require('opencode.ui.renderer.flush')
    flush.flush()

    config.ui.questions.use_vim_ui_select = true
    local original_select = vim.ui.select
    vim.ui.select = function() end
    question_window.show_question({
      id = 'q-selector',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Pick one', options = { { label = 'Two' } } } },
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
    local replies = {}
    local rejections = {}
    bind_observation(replies, rejections)
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end
    question_window._current_question = {
      id = 'q-custom-cancel',
      fields = {
        { prompt = 'Pick one', options = { { label = 'One' } } },
      },
    }

    question_window._answer_with_custom()
    input_callback(nil)

    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)
    assert.are.equal('q-custom-cancel', question_window._current_question.id)
    vim.ui.input = original_input
  end)

  it('restores the triggering backend when a selected custom answer is cancelled', function()
    helpers.replay_setup()
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = {}
    local rejections = {}
    bind_observation(replies, rejections)
    local original_input = vim.ui.input
    local input_callback
    vim.ui.input = function(_, callback)
      input_callback = callback
    end

    question_window.show_question({
      id = 'q-dialog-custom-cancel',
      status = 'pending',
      session_id = 'sess1',
      fields = { { key = 'choice', prompt = 'Pick one', type = 'string', options = { { label = 'One' } } } },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    assert.is_true(vim.wait(200, function()
      return input_callback ~= nil
    end))
    input_callback(nil)

    assert.is_false(question_window._answering)
    assert.is_true(question_window._dialog:is_active())
    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)

    local original_select = vim.ui.select
    local callbacks = {}
    vim.ui.select = function(_, _, callback)
      table.insert(callbacks, callback)
    end
    config.ui.questions.use_vim_ui_select = true
    input_callback = nil
    question_window.show_question({
      id = 'q-select-custom-cancel',
      status = 'pending',
      fields = { { key = 'choice', prompt = 'Pick one', type = 'string', options = { { label = 'One' } } } },
    })
    callbacks[1]('Other', 2)
    input_callback(nil)

    assert.is_false(question_window._answering)
    assert.are.equal(2, #callbacks)
    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)

    callbacks[2]('One', 1)
    assert.are.equal(1, #replies)

    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
    vim.ui.input = original_input
    vim.ui.select = original_select
  end)

  it('uses vim.ui.select for every single question and Dialog for mixed requests', function()
    local replies = {}
    bind_observation(replies, {})
    config.ui.questions.use_vim_ui_select = true

    local original_select = vim.ui.select
    local callbacks = {}
    vim.ui.select = function(_, _, callback)
      table.insert(callbacks, callback)
    end

    question_window.show_question({
      id = 'q-all-single',
      status = 'pending',
      fields = {
        { key = 'first', prompt = 'First', type = 'string', options = { { label = 'One' } } },
        { key = 'second', prompt = 'Second', type = 'string', options = { { label = 'Two' } } },
      },
    })
    assert.are.equal(1, #callbacks)
    callbacks[1]('One', 1)
    assert.are.equal(2, #callbacks)
    callbacks[2]('Two', 1)
    assert.are.same({ first = 'One', second = 'Two' }, replies[1].answers)

    vim.ui.select = original_select

    helpers.replay_setup()
    vim.api.nvim_set_current_win(state.windows.output_win)
    question_window.show_question({
      id = 'q-mixed',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        { prompt = 'First', options = { { label = 'One' } } },
        { prompt = 'Second', type = 'multiselect', options = { { label = 'Two' } } },
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
    vim.api.nvim_set_current_win(state.windows.output_win)
    config.ui.questions.inline_other_input = false

    local replies = {}
    local rejections = {}
    bind_observation(replies, rejections)

    local function replace_with_q2()
      question_window.show_question({
        id = 'q2',
        status = 'pending',
        session_id = 'sess1',
        fields = {
          { prompt = 'Current', type = 'multiselect', options = { { label = 'Two' } } },
        },
      })
    end

    question_window.show_question({
      id = 'q1-option',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Old', custom = false, options = { { label = 'One' } } } },
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
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Old', options = { { label = 'One' } } } },
    })
    question_window._answer_with_custom()
    replace_with_q2()
    input_callback('stale custom')

    question_window.show_question({
      id = 'q1-multi',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Old', type = 'multiselect', options = { { label = 'One' } } } },
    })
    question_window._dialog:set_selection(2)
    question_window._dialog:select()
    replace_with_q2()
    input_callback('stale multi custom')

    question_window.show_question({
      id = 'q1-submit',
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Old', type = 'multiselect', custom = false, options = { { label = 'One' } } } },
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
      status = 'pending',
      session_id = 'sess1',
      fields = { { prompt = 'Old', options = { { label = 'One' } } } },
    })
    replace_with_q2()
    select_callback(nil)

    assert.are.equal(0, #replies)
    assert.are.equal(0, #rejections)
    assert.are.equal('q2', question_window._current_question.id)
    assert.is_false(question_window._answering)
    assert.is_true(question_window._dialog:is_active())
    assert.is_nil(question_window._multi_selections[1])

    question_window.clear_question()
    require('opencode.ui.ui').close_windows(state.windows)
    vim.ui.input = original_input
    vim.ui.select = original_select
  end)

  it('keeps separate custom drafts for each question and clears them for a new request', function()
    helpers.replay_setup()
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
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          title = 'First',
          prompt = 'First custom answer',
          options = { { label = 'One' } },
        },
        {
          title = 'Second',
          prompt = 'Second custom answer',
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
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          prompt = 'New custom answer',
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

  it('shows only pending forms from the Observation question facts', function()
    local request = {
      id = 'question_1',
      session_id = 'sess1',
      status = 'pending',
      fields = {
        { key = 'choice', prompt = 'Pick one', type = 'string', options = { { label = 'One' } } },
      },
    }
    local observation = {
      read = function()
        return { question_requests_by_id = { [request.id] = request } }
      end,
    }

    question_window.sync({ observation })
    assert.are.equal(request, question_window.get_current_request())

    request.status = 'answered'
    question_window.sync({ observation })
    assert.is_nil(question_window.get_current_request())

    question_window.sync({ observation })
    assert.is_nil(question_window.get_current_request())
  end)

  it('routes each observed question reply to its owning Observation', function()
    local replies = {}
    local function observed(session_id, request_id)
      return {
        read = function()
          return {
            question_requests_by_id = {
              [request_id] = {
                id = request_id,
                session_id = session_id,
                status = 'pending',
                fields = { { key = 'answer', prompt = 'Answer', type = 'string', options = {} } },
              },
            },
          }
        end,
        reply_question = function(_, id)
          replies[#replies + 1] = session_id .. ':' .. id
          return Promise.new():resolve(true)
        end,
      }
    end
    local first = observed('ses_a', 'question_a')
    local second = observed('ses_b', 'question_b')
    local show = stub(question_window, 'show_question')
    question_window.sync({ first, second })

    question_window._send_reply('question_b', { answer = 'yes' }):await()

    assert.are.same({ 'ses_b:question_b' }, replies)
    show:revert()
  end)

  it('does not force-scroll on question navigation redraws', function()
    helpers.replay_setup()
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
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          prompt = 'Pick one',
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
    vim.api.nvim_set_current_win(state.windows.output_win)

    question_window.show_question({
      id = 'q-nav-groups',
      status = 'pending',
      session_id = 'sess1',
      fields = {
        {
          title = 'First',
          prompt = 'Pick one',
          options = {
            { label = 'One' },
          },
        },
        {
          title = 'Second',
          prompt = 'Pick two',
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
