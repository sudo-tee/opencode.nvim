local state = require('opencode.state')
local loading_animation = require('opencode.ui.loading_animation')

describe('loading_animation status text', function()
  local original_time

  before_each(function()
    original_time = os.time
    loading_animation._animation.status_data = nil
    state.active_session = nil
  end)

  after_each(function()
    os.time = original_time
    loading_animation._animation.status_data = nil
    state.active_session = nil
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
    state.active_session = { id = 'ses_active' }
    loading_animation._animation.status_data = nil

    loading_animation.on_session_status({
      sessionID = 'ses_other',
      status = { type = 'retry', message = 'Provider is overloaded' },
    })

    assert.is_nil(loading_animation._animation.status_data)
  end)
end)
