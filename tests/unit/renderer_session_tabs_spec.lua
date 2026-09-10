local state = require('opencode.state')
local store = require('opencode.state.store')
local session_tabs = require('opencode.state.session_tabs')
local renderer = require('opencode.ui.renderer')
local renderer_ctx = require('opencode.ui.renderer.ctx')
local session = require('opencode.session')
local Promise = require('opencode.promise')
local stub = require('luassert.stub')

describe('renderer session tab contexts', function()
  local original_state
  local output_buf
  local output_win

  before_each(function()
    original_state = vim.deepcopy(store.state())
    session_tabs.reset()
    renderer_ctx:reset()
    state.ui.set_windows(nil)
  end)

  after_each(function()
    if output_win and vim.api.nvim_win_is_valid(output_win) then
      pcall(vim.api.nvim_win_close, output_win, true)
    end
    if output_buf and vim.api.nvim_buf_is_valid(output_buf) then
      pcall(vim.api.nvim_buf_delete, output_buf, { force = true })
    end
    output_win = nil
    output_buf = nil
    state.ui.set_windows(nil)
    renderer_ctx:reset()
    session_tabs.reset()
    for key, value in pairs(original_state) do
      store.set_raw(key, value)
    end
  end)

  it('restores a cached renderer context without rerendering the output buffer', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'One' }

    renderer_ctx:reset()
    renderer_ctx.formatted_messages = { first = true }
    first.renderer_context = renderer_ctx:snapshot()

    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    renderer_ctx:reset()
    renderer_ctx.formatted_messages = { second = true }
    second.renderer_context = renderer_ctx:snapshot()
    renderer_ctx:restore(first.renderer_context)

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 60,
      height = 10,
      row = 1,
      col = 1,
    })
    vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, { 'preserved output' })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })

    store.set_raw('active_session_tab', second.id)
    store.set_raw('active_session', second.active_session)
    store.set_raw('messages', {})

    local render_stub = stub(renderer, 'render_full_session').returns(Promise.new():resolve(nil))
    renderer.on_session_tab_changed(nil, second.id, first.id)

    assert.stub(render_stub).was_not_called()
    assert.equals(second.renderer_context.render_state, renderer_ctx.render_state)
    assert.same({ 'preserved output' }, vim.api.nvim_buf_get_lines(output_buf, 0, -1, false))
    render_stub:revert()
  end)

  it('refreshes a dirty cached renderer context on activation', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'One' }
    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    second.renderer_context = renderer_ctx:snapshot()
    second.renderer_dirty = true

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 60,
      height = 10,
      row = 1,
      col = 1,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
    state.jobs.set_api_client({})
    store.set_raw('active_session_tab', second.id)
    store.set_raw('active_session', second.active_session)

    local render_stub = stub(renderer, 'render_full_session').returns(Promise.new():resolve({}))
    renderer.on_session_tab_changed(nil, second.id, first.id)

    assert.stub(render_stub).was_called(1)
    vim.wait(50, function()
      return not second.renderer_dirty
    end)
    assert.is_false(second.renderer_dirty)
    render_stub:revert()
  end)

  it('does not clear dirty state when refresh cannot load messages', function()
    local first = session_tabs.ensure_current()
    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    second.renderer_context = renderer_ctx:snapshot()
    second.renderer_dirty = true
    store.set_raw('active_session_tab', second.id)
    store.set_raw('active_session', second.active_session)

    local render_stub = stub(renderer, 'render_full_session').returns(Promise.new():resolve(nil))
    renderer.on_session_tab_changed(nil, second.id, first.id)
    vim.wait(20)

    assert.is_true(second.renderer_dirty)
    render_stub:revert()
  end)

  it('refreshes a dirty tab after its windows are mounted', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'One' }
    local second = session_tabs.create({ id = 'session-two', title = 'Two' })
    second.renderer_dirty = false

    store.set_raw('active_session_tab', second.id)
    store.set_raw('active_session', second.active_session)
    renderer.on_session_tab_changed(nil, second.id, first.id)
    assert.is_true(second.renderer_dirty)

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 60,
      height = 10,
      row = 1,
      col = 1,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
    state.jobs.set_api_client({})

    local render_stub = stub(renderer, 'render_full_session').returns(Promise.new():resolve({}))
    renderer.on_windows_mounted()

    vim.wait(20, function()
      return not second.renderer_dirty
    end)
    assert.stub(render_stub).was_called(1)
    assert.is_false(second.renderer_dirty)
    render_stub:revert()
  end)

  it('marks an in-flight render dirty when its tab becomes inactive', function()
    local first = session_tabs.ensure_current()
    first.active_session = { id = 'session-one', title = 'One' }
    local second = session_tabs.create({ id = 'session-two', title = 'Two' })

    output_buf = vim.api.nvim_create_buf(false, true)
    output_win = vim.api.nvim_open_win(output_buf, false, {
      relative = 'editor',
      width = 60,
      height = 10,
      row = 1,
      col = 1,
    })
    state.ui.set_windows({ output_buf = output_buf, output_win = output_win })
    state.jobs.set_api_client({})
    store.set_raw('active_session', first.active_session)
    store.set_raw('active_session_tab', first.id)

    local messages = Promise.new()
    local messages_stub = stub(session, 'get_messages').returns(messages)
    renderer.render_full_session()

    store.set_raw('active_session', second.active_session)
    store.set_raw('active_session_tab', second.id)
    messages:resolve({})
    vim.wait(50, function()
      return first.renderer_dirty
    end)

    assert.is_true(first.renderer_dirty)
    messages_stub:revert()
  end)
end)
