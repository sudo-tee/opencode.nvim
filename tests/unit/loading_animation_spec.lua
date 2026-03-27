local state = require('opencode.state')
local loading_animation = require('opencode.ui.loading_animation')

describe('loading_animation status text', function()
  local original_time
  local original_windows

  before_each(function()
    original_time = os.time
    original_windows = state.windows
    loading_animation._animation.status_data = nil
    state.session.clear_active()
    state.session.set_user_message_count({})
  end)

  after_each(function()
    os.time = original_time
    loading_animation._animation.status_data = nil
    state.session.clear_active()
    state.session.set_user_message_count({})
    state.ui.set_windows(original_windows)
  end)

  it('renders busy as thinking text', function()
    local text = loading_animation._format_status_text({ type = 'busy' })
    assert.are.equal('Thinking... ', text)
  end)

  it('counts down retry seconds dynamically', function()
    loading_animation._animation.status_data = {
      type = 'retry',
      message = 'Provider is overloaded',
      attempt = 2,
      next = 1018000,
    }

    os.time = function()
      return 1000
    end
    local first = loading_animation._get_display_text()

    os.time = function()
      return 1005
    end
    local second = loading_animation._get_display_text()

    assert.is_truthy(first:find('in 18s', 1, true))
    assert.is_truthy(second:find('in 13s', 1, true))
  end)

  it('ignores status updates for non-active sessions', function()
    state.session.set_active({ id = 'ses_active' })
    loading_animation._animation.status_data = nil

    loading_animation.on_session_status({
      sessionID = 'ses_other',
      status = { type = 'retry', message = 'Provider is overloaded' },
    })

    assert.is_nil(loading_animation._animation.status_data)
  end)

  it('treats pending work on the active session as busy', function()
    state.session.set_active({ id = 'ses_active' })
    state.session.set_user_message_count({ ses_active = 1 })

    assert.is_true(loading_animation._get_display_text():find('Thinking', 1, true) ~= nil)
  end)

  it('starts when the active session still has pending work after reopening', function()
    local output_buf = vim.api.nvim_create_buf(false, true)
    local footer_buf = vim.api.nvim_create_buf(false, true)
    state.ui.set_windows({ output_buf = output_buf, footer_buf = footer_buf })
    state.session.set_active({ id = 'ses_active' })
    state.session.set_user_message_count({ ses_active = 1 })

    loading_animation.setup()

    assert.is_true(loading_animation.is_running())

    loading_animation.teardown()
    pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, footer_buf, { force = true })
  end)

  it('keeps spinner active while the active session has a pending question', function()
    local question_window = require('opencode.ui.question_window')
    state.session.set_active({ id = 'ses_active' })
    question_window._current_question = {
      id = 'q1',
      sessionID = 'ses_active',
      questions = {
        {
          question = 'Pick one',
          header = 'Test',
          options = { { label = 'One', description = 'first' } },
        },
      },
    }

    assert.is_true(loading_animation._get_display_text():find('Thinking', 1, true) ~= nil)

    question_window._current_question = nil
  end)
end)
