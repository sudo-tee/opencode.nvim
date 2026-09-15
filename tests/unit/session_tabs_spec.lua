local state = require('opencode.state')
local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('opencode session panel tabs', function()
  local original_state

  before_each(function()
    original_state = vim.deepcopy(store.state())
    session_tabs.reset()
  end)

  after_each(function()
    vim.wait(50)
    session_tabs.reset()
    for key, value in pairs(original_state) do
      store.set(key, value)
    end
    vim.wait(50)
  end)

  it('keeps session state isolated when switching logical tabs', function()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one', title = 'One' })
    state.renderer.set_messages({ { info = { id = 'message-one' }, parts = {} } })
    state.ui.set_input_content({ 'prompt for one' })

    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    session_tabs.activate(second)
    state.renderer.set_messages({ { info = { id = 'message-two' }, parts = {} } })
    state.ui.set_input_content({ 'prompt for two' })

    session_tabs.activate(first)

    assert.equals('session-one', state.active_session.id)
    assert.equals('message-one', state.messages[1].info.id)
    assert.same({ 'prompt for one' }, state.input_content)

    session_tabs.activate(second)

    assert.equals('session-two', state.active_session.id)
    assert.equals('message-two', state.messages[1].info.id)
    assert.same({ 'prompt for two' }, state.input_content)
  end)

  it('creates new tabs without reusing the active tab UI state', function()
    session_tabs.ensure_current()
    state.ui.set_windows({ input_buf = 10, output_buf = 11 })
    state.ui.set_input_content({ 'old input' })

    local runtime = session_tabs.create({ id = 'new-session' })

    assert.is_nil(runtime.windows)
    assert.same({}, runtime.input_content)
    assert.equals('old input', state.input_content[1])
  end)

  it('updates a background tab message count without changing the active tab', function()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one' })
    local second = session_tabs.create({ id = 'session-two' })
    session_tabs.activate(second)

    session_tabs.update_user_message_count(first.id, 'session-one', 1)

    assert.same({}, state.user_message_count)
    assert.equals(1, first.user_message_count['session-one'])
    assert.equals('session-two', state.active_session.id)
  end)

  it('notifies active-tab subscribers when message counts change', function()
    local first = session_tabs.ensure_current()
    state.session.set_active({ id = 'session-one' })
    local notifications = 0
    local listener = function()
      notifications = notifications + 1
    end
    store.subscribe('user_message_count', listener)

    session_tabs.update_user_message_count(first.id, 'session-one', 1)
    vim.wait(50, function()
      return notifications == 1
    end)
    session_tabs.update_user_message_count(first.id, 'session-one', -1)
    vim.wait(50, function()
      return notifications == 2
    end)

    assert.equals(2, notifications)
    assert.equals(0, state.user_message_count['session-one'])
    store.unsubscribe('user_message_count', listener)
  end)

  it('switches to a panel tab by displayed index', function()
    local session_runtime = require('opencode.services.session_runtime')
    local first = session_tabs.ensure_current()
    local second = session_tabs.create({ id = 'session-two' })
    local switch_stub = stub(session_runtime, 'switch_session_tab').returns(Promise.new():resolve(nil))

    session_runtime.switch_session_tab_by_index(2):await()

    assert.stub(switch_stub).was_called_with(second.id)
    assert.equals('tab-1', first.id)
    switch_stub:revert()
  end)

  it('mounts each tab with its own output and input buffers', function()
    local session_runtime = require('opencode.services.session_runtime')
    local server_job = require('opencode.server_job')
    local agent_model = require('opencode.services.agent_model')
    local renderer = require('opencode.ui.renderer')
    local ui = require('opencode.ui.ui')

    local server = {
      is_running = function()
        return true
      end,
      check_health = function()
        return Promise.new():resolve(true)
      end,
      shutdown = function() end,
    }

    state.jobs.set_server(server)
    state.jobs.set_api_client({})
    state.context.set_current_cwd(vim.fn.getcwd())

    local create_session_stub =
      stub(session_runtime, 'create_new_session').returns(Promise.new():resolve({ id = 'session-two', title = 'Two' }))
    local ensure_server_stub = stub(server_job, 'ensure_server').returns(Promise.new():resolve(server))
    local ensure_mode_stub = stub(agent_model, 'ensure_current_mode').returns(Promise.new():resolve(true))
    local render_stub = stub(renderer, 'render_full_session').returns(Promise.new():resolve(nil))

    state.session.set_active({ id = 'session-one', title = 'One' })
    session_runtime.open({ focus = 'output', open_action = 'create_fresh' }):await()
    local first_output = state.windows.output_buf
    local first_input = state.windows.input_buf
    require('opencode.ui.output_window').set_lines({ 'first output' })
    require('opencode.ui.input_window').set_content({ 'first input' })

    session_runtime.open_session_tab('Two'):await()
    local second_output = state.windows.output_buf
    local second_input = state.windows.input_buf
    require('opencode.ui.output_window').set_lines({ 'second output' })
    require('opencode.ui.input_window').set_content({ 'second input' })

    assert.is_not.equal(first_output, second_output)
    assert.is_not.equal(first_input, second_input)

    local tabs = session_tabs.list()
    local first_tab
    local second_tab
    for _, tab in ipairs(tabs) do
      if tab.active_session and tab.active_session.id == 'session-one' then
        first_tab = tab
      elseif tab.active_session and tab.active_session.id == 'session-two' then
        second_tab = tab
      end
    end
    assert.is_not_nil(first_tab)
    assert.is_not_nil(second_tab)

    session_runtime.switch_session_tab(first_tab.id):await()
    assert.equals(first_output, state.windows.output_buf)
    assert.same({ 'first input' }, vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false))
    assert.equals(state.windows.output_win, vim.api.nvim_get_current_win())

    session_runtime.switch_session_tab(second_tab.id):await()
    assert.equals(second_output, state.windows.output_buf)
    assert.same({ 'second input' }, vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false))
    assert.equals(state.windows.input_win, vim.api.nvim_get_current_win())

    if state.windows then
      ui.teardown_visible_windows(state.windows)
    end
    for _, tab in ipairs(session_tabs.list()) do
      for _, buf in ipairs({
        tab.windows and tab.windows.input_buf,
        tab.windows and tab.windows.output_buf,
        tab.windows and tab.windows.footer_buf,
        tab.windows and tab.windows.tab_strip_buf,
      }) do
        if buf and vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
    create_session_stub:revert()
    ensure_server_stub:revert()
    ensure_mode_stub:revert()
    render_stub:revert()
  end)
end)
