local renderer = require('opencode.ui.renderer')
local ctx = require('opencode.ui.renderer.ctx')
local flush = require('opencode.ui.renderer.flush')
local output_window = require('opencode.ui.output_window')
local helpers = require('tests.helpers')
local state = require('opencode.state')
local config = require('opencode.config')
local stub = require('luassert.stub')
local spy = require('luassert.spy')

describe('renderer incremental reconciliation', function()
  local observed, observation, changed, controllers, writes, markdown, dirty_part, dirty_message, max_messages, throttle_ms, collapsing, defer_stub, files_stub

  local function notify(resource)
    changed(observation, resource)
    local done = false
    vim.schedule(function()
      done = true
    end)
    assert.is_true(vim.wait(1000, function()
      return done and not ctx.reconcile_scheduled and not ctx.flush_scheduled
    end))
  end

  before_each(function()
    helpers.replay_setup()
    max_messages = config.ui.output.max_messages
    throttle_ms = config.ui.output.rendering.event_throttle_ms
    collapsing = config.ui.output.rendering.event_collapsing
    controllers = ctx.prompt_controllers
    ctx.prompt_controllers = {}
    observed = {
      session = { id = 'ses_incremental' },
      sync = { session = { state = 'current' }, messages = { state = 'current' } },
      children = { order = {}, by_id = {} },
      files = { revision = 0 },
      entry_order = { 'msg_one', 'msg_two' },
      entries_by_id = {},
    }
    for index, id in ipairs(observed.entry_order) do
      observed.entries_by_id[id] = {
        id = id, session_id = 'ses_incremental', kind = 'assistant', agent = 'build',
        content = { { id = 'part_' .. index, kind = 'text', text = 'message ' .. index } },
      }
    end
    local watchers = {}
    observation = {
      read = function() return observed end,
      watch = function(_, _, callback)
        watchers[#watchers + 1] = callback
        changed = function(source, resource)
          for _, watcher in ipairs(watchers) do
            watcher(source, resource)
          end
        end
        return function()
          for index = #watchers, 1, -1 do
            if watchers[index] == callback then
              table.remove(watchers, index)
              break
            end
          end
        end
      end,
    }
    state.jobs.set_server({ is_ready = function() return true end, observe = function() return observation end })
    state.session.set_active({ id = 'ses_incremental' })
    renderer.on_session_changed(nil, state.active_session, nil)
    vim.wait(50, function() return false end)
    writes = stub(output_window, 'set_lines')
    markdown = stub(flush, 'request_on_data_rendered')
    dirty_part = spy.on(flush, 'mark_part_dirty')
    dirty_message = spy.on(flush, 'mark_message_dirty')
  end)

  after_each(function()
    config.ui.output.max_messages = max_messages
    config.ui.output.rendering.event_throttle_ms = throttle_ms
    config.ui.output.rendering.event_collapsing = collapsing
    if defer_stub then defer_stub:revert(); defer_stub = nil end
    if files_stub then files_stub:revert(); files_stub = nil end
    writes:revert()
    markdown:revert()
    dirty_part:revert()
    dirty_message:revert()
    renderer.teardown()
    ctx.prompt_controllers = controllers
    state.session.clear_active()
    state.jobs.clear_server()
    if state.windows then require('opencode.ui.ui').close_windows(state.windows) end
  end)

  it('writes the initial observed history once and preserves all rendered ranges', function()
    writes:revert()
    ctx:reset()
    ctx.lazy_render_count = math.huge
    output_window.clear()
    writes = spy.on(output_window, 'set_lines')
    observed.entry_order = {}
    observed.entries_by_id = {}
    for index = 1, 40 do
      local id = 'msg_' .. index
      observed.entry_order[index] = id
      observed.entries_by_id[id] = {
        id = id, session_id = 'ses_incremental', kind = index % 2 == 0 and 'user' or 'assistant',
        agent = 'build',
        content = {
          { id = id .. '_text', kind = 'text', text = 'first part ' .. index },
          { id = id .. '_tail', kind = 'text', text = 'second part ' .. index },
        },
      }
    end
    notify('messages')
    assert.spy(writes).was_called(1)
    local lines = vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false)
    for index = 1, 40 do
      local id = 'msg_' .. index
      local first = ctx.render_state:get_part(id .. '_text')
      local tail = ctx.render_state:get_part(id .. '_tail')
      assert.equals('first part ' .. index, lines[first.line_start + 1])
      assert.equals('second part ' .. index, lines[tail.line_start + 1])
      assert.is_true(ctx.render_state:get_message(id).line_end < first.line_start)
      assert.is_true(first.line_end < tail.line_start)
    end
    assert.is_false(ctx.bulk_mode)
    notify('messages')
    assert.spy(writes).was_called(1)
  end)

  it('keeps the hidden-history notice above messages in the initial batch', function()
    writes:revert()
    ctx:reset()
    output_window.clear()
    writes = spy.on(output_window, 'set_lines')
    config.ui.output.max_messages = 1
    notify('messages')
    assert.spy(writes).was_called(1)
    local notice = ctx.render_state:get_part('__opencode_hidden_messages_notice_part__')
    local message = ctx.render_state:get_message('msg_two')
    assert.is_not_nil(notice)
    assert.is_true(notice.line_end < message.line_start)
    assert.is_nil(ctx.render_state:get_message('msg_one'))
  end)

  it('ignores execution updates and unchanged messages', function()
    notify('execution')
    notify('messages')
    assert.spy(dirty_message).was_not_called()
    assert.spy(dirty_part).was_not_called()
    assert.stub(writes).was_not_called()
    assert.stub(markdown).was_not_called()
  end)

  it('does not collect candidate files for empty flushes or header-only updates', function()
    files_stub = stub(require('opencode.ui.reference_facts'), 'available_files').returns({})
    flush.flush()
    flush.flush()
    flush.mark_message_dirty('msg_one')
    flush.flush()
    assert.stub(files_stub).was_not_called()
    assert.stub(writes).was_not_called()
  end)

  it('renders a streaming burst once at a fixed deadline using the latest data', function()
    local callbacks = {}
    config.ui.output.rendering.event_throttle_ms = 40
    config.ui.output.rendering.event_collapsing = true
    defer_stub = stub(vim, 'defer_fn').invokes(function(callback, delay)
      assert.equals(40, delay)
      callbacks[#callbacks + 1] = callback
    end)
    for index = 1, 100 do
      observed.entries_by_id.msg_two.content[1].text = 'streaming delta ' .. index
      changed(observation, 'messages')
    end
    assert.equals(1, #callbacks)
    assert.is_true(ctx.reconcile_scheduled)
    assert.stub(writes).was_not_called()
    callbacks[1]()
    assert.is_false(ctx.reconcile_scheduled)
    assert.stub(writes).was_called(1)
    assert.spy(dirty_part).was_called(1)
    assert.equals('streaming delta 100', ctx.formatted_parts.part_2.lines[1])
  end)

  it('discards a delayed render after its context is reset', function()
    local callback
    defer_stub = stub(vim, 'defer_fn').invokes(function(fn) callback = fn end)
    config.ui.output.rendering.event_throttle_ms = 40
    config.ui.output.rendering.event_collapsing = true
    observed.entries_by_id.msg_two.content[1].text = 'old context update'
    changed(observation, 'messages')
    assert.is_not_nil(callback)
    ctx:reset()
    callback()
    assert.stub(writes).was_not_called()
    assert.is_false(ctx.reconcile_scheduled)
  end)

  it('flushes the latest delayed text before detaching a session tab', function()
    local callback
    defer_stub = stub(vim, 'defer_fn').invokes(function(fn) callback = fn end)
    config.ui.output.rendering.event_throttle_ms = 40
    config.ui.output.rendering.event_collapsing = true
    observed.entries_by_id.msg_two.content[1].text = 'latest text before switching'
    changed(observation, 'messages')
    renderer.prepare_session_tab_switch()
    assert.equals('latest text before switching', ctx.formatted_parts.part_2.lines[1])
    assert.stub(writes).was_called(1)
    callback()
    assert.stub(writes).was_called(1)
  end)

  it('does not let a drained callback consume a newer batch', function()
    local callbacks = {}
    defer_stub = stub(vim, 'defer_fn').invokes(function(callback)
      callbacks[#callbacks + 1] = callback
    end)
    config.ui.output.rendering.event_throttle_ms = 40
    config.ui.output.rendering.event_collapsing = true
    observed.entries_by_id.msg_two.content[1].text = 'before detach'
    changed(observation, 'messages')
    renderer.prepare_session_tab_switch()
    assert.is_false(ctx.reconcile_scheduled)
    assert.stub(writes).was_called(1)

    observed.entries_by_id.msg_two.content[1].text = 'new batch'
    changed(observation, 'messages')
    callbacks[1]()
    assert.is_true(ctx.reconcile_scheduled)
    assert.stub(writes).was_called(1)
    callbacks[2]()
    assert.is_false(ctx.reconcile_scheduled)
    assert.stub(writes).was_called(2)
    assert.equals('new batch', ctx.formatted_parts.part_2.lines[1])
  end)

  it('can disable the streaming delay', function()
    config.ui.output.rendering.event_throttle_ms = 0
    defer_stub = stub(vim, 'defer_fn')
    observed.entries_by_id.msg_two.content[1].text = 'immediate update'
    notify('messages')
    assert.stub(defer_stub).was_not_called()
    assert.stub(writes).was_called(1)
  end)

  it('refreshes symbols without rewriting unchanged conversation text', function()
    require('opencode.ui.renderer.symbol_refresh').invalidate()
    flush.flush()
    assert.stub(writes).was_not_called()
    assert.stub(markdown).was_not_called()
  end)

  it('detects in-place streaming mutations and dirties only the changed part', function()
    observed.entries_by_id.msg_two.content[1].text = 'message 2 updated'
    notify('messages')
    assert.spy(dirty_message).was_not_called()
    assert.spy(dirty_part).was_called(1)
    assert.spy(dirty_part).was_called_with('part_2', 'msg_two')
    assert.stub(writes).was_called(1)
    assert.stub(markdown).was_called(1)
  end)

  it('keeps formatted headers when explicitly dirtied', function()
    flush.mark_message_dirty('msg_one')
    flush.mark_part_dirty('part_1', 'msg_one')
    flush.flush()
    assert.stub(writes).was_not_called()
    assert.stub(markdown).was_not_called()
  end)

  it('refreshes target metadata without writing unchanged markdown', function()
    local formatted = vim.deepcopy(ctx.formatted_parts.part_1)
    formatted.targets = {
      { kind = 'file', path = 'updated.lua', range = { line = 1, start_col = 0, end_col = 5 } },
    }
    local format = stub(require('opencode.ui.formatter'), 'format_part').returns(formatted)
    flush.mark_part_dirty('part_1', 'msg_one')
    flush.flush()
    format:revert()
    assert.equals('updated.lua', ctx.render_state:get_part('part_1').targets[1].path)
    assert.stub(writes).was_not_called()
    assert.stub(markdown).was_not_called()
  end)

  it('updates permission controllers without dirtying conversation content', function()
    local sync = spy.new(function() end)
    ctx.prompt_controllers.permission = {
      sync = sync,
      clear_all = function() end,
      get_all_permissions = function() return {} end,
    }
    notify('permissions')
    assert.spy(sync).was_called(1)
    assert.spy(dirty_message).was_not_called()
    assert.spy(dirty_part).was_not_called()
    assert.stub(writes).was_not_called()
  end)

  it('renders observed data synchronously and reports when no output can be rendered', function()
    observed.entries_by_id.msg_two.content[1].text = 'synchronous update'
    assert.is_true(renderer.render_full_session())
    assert.equals('synchronous update', ctx.formatted_parts.part_2.lines[1])
    assert.stub(writes).was_called(1)
    ctx.observation = nil
    assert.is_false(renderer.render_full_session())
    ctx.observation = observation
    assert.stub(writes).was_called(1)
  end)

  it('handles both prompt resources once when they share a batch', function()
    local permission_sync, question_sync = spy.new(function() end), spy.new(function() end)
    ctx.prompt_controllers = {
      permission = {
        sync = permission_sync,
        clear_all = function() end,
        get_all_permissions = function() return {} end,
      },
      question = {
        sync = question_sync,
        clear_all = function() end,
        get_current_request = function() return nil end,
        has_question = function() return false end,
      },
    }
    changed(observation, 'permissions')
    notify('questions')
    assert.spy(permission_sync).was_called(1)
    assert.spy(question_sync).was_called(1)
    assert.spy(dirty_message).was_not_called()
    assert.spy(dirty_part).was_not_called()
    assert.stub(writes).was_not_called()
  end)

  it('coalesces notifications and ignores loading transitions', function()
    observed.sync.messages.state = 'loading'
    notify('messages')
    assert.spy(dirty_part).was_not_called()
    observed.sync.messages.state = 'current'
    observed.entries_by_id.msg_two.content[1].text = 'coalesced update'
    changed(observation, 'messages')
    changed(observation, 'session')
    notify('messages')
    assert.spy(dirty_part).was_called(1)
    assert.stub(writes).was_called(1)
  end)

  it('removes only the removed part range', function()
    observed.entries_by_id.msg_two.content = {}
    notify('messages')
    assert.is_nil(ctx.render_state:get_part('part_2'))
    assert.is_not_nil(ctx.render_state:get_part('part_1'))
    assert.stub(writes).was_called(1)
  end)

  it('removes only the removed message and its parts', function()
    observed.entry_order = { 'msg_one' }
    observed.entries_by_id.msg_two = nil
    notify('messages')
    assert.is_nil(ctx.render_state:get_message('msg_two'))
    assert.is_nil(ctx.render_state:get_part('part_2'))
    assert.is_not_nil(ctx.render_state:get_message('msg_one'))
    assert.is_not_nil(ctx.render_state:get_part('part_1'))
    assert.stub(writes).was_called(2)
  end)

  it('preserves independent snapshots when restoring a session tab', function()
    local snapshot = ctx:snapshot()
    ctx:reset()
    ctx:restore(snapshot)
    renderer.render_full_session()
    assert.spy(dirty_message).was_not_called()
    assert.spy(dirty_part).was_not_called()
  end)
end)
