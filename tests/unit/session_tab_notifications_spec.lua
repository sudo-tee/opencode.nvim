local state = require('opencode.state')
local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')
local notifications = require('opencode.ui.session_tab_notifications')
local config = require('opencode.config')

describe('opencode session tab notifications', function()
  local original_state
  local original_config

  before_each(function()
    original_state = vim.deepcopy(store.state())
    original_config = vim.deepcopy(config.values)
    session_tabs.reset()
    notifications.reset()
  end)

  after_each(function()
    session_tabs.reset()
    notifications.reset()
    for key, value in pairs(original_state) do
      store.set_raw(key, value)
    end
    config.values = original_config
  end)

  it('tracks background prompts and notifies once per request', function()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one', title = 'One' })
    local second = session_tabs.create({ id = 'session-two', title = 'Second' })
    local original_notify = vim.notify
    local notify_calls = {}
    vim.notify = function(message, level)
      table.insert(notify_calls, { message = message, level = level })
    end

    local permission = { id = 'permission-one', sessionID = 'session-two' }
    notifications.track_permission(permission)
    notifications.track_permission(permission)

    assert.same({ permission }, second.pending_prompt_permissions)
    assert.equals(1, #notify_calls)
    assert.same({ message = 'Permission required in session "Second"', level = vim.log.levels.WARN }, notify_calls[1])

    local question = { id = 'question-one', sessionID = 'session-two', questions = {} }
    notifications.track_question(question)
    assert.same({ question }, second.pending_questions)
    assert.same({ message = 'Question waiting in session "Second"', level = vim.log.levels.INFO }, notify_calls[2])

    notifications.clear_permission(permission.id)
    notifications.clear_question(question.id)
    assert.same({}, second.pending_prompt_permissions)
    assert.same({}, second.pending_questions)
    assert.equals('session-one', first.active_session.id)

    vim.notify = original_notify
  end)

  it('keeps markers without notifying when background prompt notifications are disabled', function()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one', title = 'One' })
    local second = session_tabs.create({ id = 'session-two', title = 'Second' })
    config.values.ui.notify_on_background_prompt = false

    local original_notify = vim.notify
    local notify_count = 0
    vim.notify = function()
      notify_count = notify_count + 1
    end

    local question = { id = 'question-one', sessionID = 'session-two', questions = {} }
    notifications.track_question(question)

    assert.same({ question }, second.pending_questions)
    assert.equals(0, notify_count)
    assert.equals('session-one', first.active_session.id)

    vim.notify = original_notify
  end)
end)
