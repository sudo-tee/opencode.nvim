local state = require('opencode.state')
local loading_animation = require('opencode.ui.loading_animation')
local footer = require('opencode.ui.footer')
local assert = require('luassert')
local support = require('tests.unit.services_spec_support')

describe('loading_animation', function()
  local original
  local original_footer_render
  local connection

  local function observed_execution(session_id, execution)
    connection.session_facts[session_id] = { id = session_id }
    local observation = connection:observe({ id = session_id })
    observation._state.execution = execution
    local watcher
    local releases = 0
    observation.watch = function(_, resources, changed)
      assert.same({ 'execution' }, resources)
      watcher = changed
      local active = true
      return function()
        if active then
          active = false
          releases = releases + 1
        end
      end
    end
    return observation, function(next_execution)
      observation._state.execution = next_execution
      if watcher then
        watcher(observation)
      end
    end, function()
      return releases
    end
  end

  before_each(function()
    original = support.snapshot_state()
    original_footer_render = footer.render
    loading_animation.teardown()
    state.store.set_raw('windows', nil)
    state.session.clear_active()
    connection = support.mock_connection()
    loading_animation._animation.execution = nil
    loading_animation._animation.session_id = nil
    loading_animation._animation.current_frame = 1
    loading_animation._animation.extmark_id = nil
    footer.render = function() end
  end)

  after_each(function()
    loading_animation.teardown()
    footer.render = original_footer_render
    support.restore_state(original)
  end)

  describe('_format_execution_text', function()
    it('returns the spinner text while running', function()
      assert.equals('Thinking... ', loading_animation._format_execution_text({ activity = 'running' }))
    end)

    it('returns nil while idle or unknown', function()
      assert.is_nil(loading_animation._format_execution_text({ activity = 'idle' }))
      assert.is_nil(loading_animation._format_execution_text({ activity = 'unknown' }))
    end)

    it('formats retry facts from the Observation contract', function()
      local text = loading_animation._format_execution_text({
        activity = 'retrying',
        retry = {
          attempt = 2,
          message = 'Provider overloaded',
          scheduled_at = os.time() * 1000 + 5000,
        },
      })
      assert.is_truthy(text:find('Provider overloaded', 1, true))
      assert.is_truthy(text:find('retry 2', 1, true))
      assert.is_truthy(text:find('in 5s', 1, true))
    end)
  end)

  describe('_should_animate', function()
    it('requires a running or retrying execution for the active session', function()
      state.session.set_active({ id = 'ses_a' })
      loading_animation._animation.session_id = 'ses_a'

      loading_animation._animation.execution = { activity = 'idle' }
      assert.is_false(loading_animation._should_animate())

      loading_animation._animation.execution = { activity = 'running' }
      assert.is_true(loading_animation._should_animate())

      loading_animation._animation.execution = { activity = 'retrying' }
      assert.is_true(loading_animation._should_animate())

      loading_animation._animation.session_id = 'ses_b'
      assert.is_false(loading_animation._should_animate())
    end)
  end)

  describe('Observation lifecycle', function()
    it('reads the active execution and follows subsequent changes', function()
      local _, change = observed_execution('ses_a', { activity = 'running' })
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })

      loading_animation.setup()
      assert.equals('running', loading_animation._animation.execution.activity)
      assert.equals('ses_a', loading_animation._animation.session_id)
      assert.is_true(loading_animation.is_running())

      change({ activity = 'idle' })
      assert.equals('idle', loading_animation._animation.execution.activity)
      assert.is_false(loading_animation.is_running())
    end)

    it('rerenders the footer when execution becomes idle', function()
      local _, change = observed_execution('ses_a', { activity = 'running' })
      local footer_renders = 0
      footer.render = function()
        footer_renders = footer_renders + 1
      end
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })

      loading_animation.setup()
      local renders_before_idle = footer_renders

      change({ activity = 'idle' })

      assert.is_true(footer_renders > renders_before_idle)
    end)

    it('releases the old watch and binds the newly active session', function()
      local _, _, first_releases = observed_execution('ses_a', { activity = 'running' })
      observed_execution('ses_b', { activity = 'idle' })
      state.session.set_active({ id = 'ses_a' })
      loading_animation.setup()

      state.session.set_active({ id = 'ses_b' })
      vim.wait(200, function()
        return loading_animation._animation.session_id == 'ses_b'
      end)

      assert.equals(1, first_releases())
      assert.equals('ses_b', loading_animation._animation.session_id)
      assert.equals('idle', loading_animation._animation.execution.activity)
    end)

    it('releases the watch and clears execution state on teardown', function()
      local _, _, releases = observed_execution('ses_a', { activity = 'running' })
      state.session.set_active({ id = 'ses_a' })
      loading_animation.setup()

      loading_animation.teardown()

      assert.equals(1, releases())
      assert.is_nil(loading_animation._animation.execution)
      assert.is_nil(loading_animation._animation.session_id)
      assert.is_nil(loading_animation._animation.timer)
    end)

    it('reads current Observation state when reopened after completion while hidden', function()
      local observation = observed_execution('ses_a', { activity = 'running' })
      state.session.set_active({ id = 'ses_a' })
      state.store.set_raw('windows', { output_buf = 1, footer_buf = 1 })
      loading_animation.setup()
      assert.is_true(loading_animation.is_running())

      loading_animation.teardown()
      observation._state.execution = { activity = 'idle' }
      loading_animation.setup()

      assert.equals('idle', loading_animation._animation.execution.activity)
      assert.is_false(loading_animation.is_running())
    end)
  end)
end)
