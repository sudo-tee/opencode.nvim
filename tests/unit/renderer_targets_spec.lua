local ctx = require('opencode.ui.renderer.ctx')
local renderer = require('opencode.ui.renderer')
local flush = require('opencode.ui.renderer.flush')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')
local state = require('opencode.state')
local config = require('opencode.config')

describe('renderer target API', function()
  local schedule_stub

  before_each(function()
    ctx:reset()
    schedule_stub = stub(flush, 'schedule')
  end)

  after_each(function()
    schedule_stub:revert()
    ctx:reset()
  end)

  it('returns rendered targets with source ids', function()
    ctx.render_state:set_part({ id = 'part1', kind = 'text' }, 'msg1', 'part1', 0, 0)
    ctx.render_state:add_targets('part1', {
      {
        kind = 'file',
        path = 'README.md',
        range = { line = 1, start_col = 0, end_col = 9 },
      },
    })

    local result = renderer.get_target_at_position(1, 4)

    assert.is_not_nil(result)
    assert.equals('README.md', result.path)
    assert.equals('part1', result.part_id)
    assert.equals('msg1', result.message_id)
  end)

  it('marks a part dirty using part_id then message_id', function()
    renderer.mark_part_dirty('part1', 'msg1')

    assert.equals('msg1', ctx.pending.dirty_parts.part1)
    assert.equals('part1', ctx.pending.dirty_part_order[1])
    assert.is_true(ctx.pending.dirty_part_by_message.msg1.part1)
  end)
end)

describe('renderer child observations', function()
  local saved_controllers

  local function observation(observed)
    local watchers = {}
    return {
      read = function()
        return observed
      end,
      watch = function(_, resources, changed)
        local watcher = { resources = resources, changed = changed, active = true }
        watchers[#watchers + 1] = watcher
        return function()
          watcher.active = false
        end
      end,
      watchers = watchers,
    }
  end

  before_each(function()
    helpers.replay_setup()
    saved_controllers = ctx.prompt_controllers
    ctx.prompt_controllers = {}
    config.ui.output.tools.show_output = true
  end)

  after_each(function()
    renderer.teardown()
    ctx.prompt_controllers = saved_controllers
    state.session.clear_active()
    state.jobs.clear_server()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('renders child tools from the child Observation and releases both subscriptions', function()
    local child = observation({
      session = { id = 'ses_child' },
      sync = { children = { state = 'current' } },
      children = { by_id = {}, order = {} },
      entry_order = { 'msg_child' },
      entries_by_id = {
        msg_child = {
          id = 'msg_child',
          session_id = 'ses_child',
          kind = 'assistant',
          content = {
            {
              id = 'tool_child',
              kind = 'tool',
              name = 'bash',
              state = 'completed',
              command = 'echo child-observation',
            },
          },
        },
      },
      permission_requests_by_id = {},
      question_requests_by_id = {},
    })
    local root = observation({
      session = { id = 'ses_root' },
      sync = { session = { state = 'current' }, children = { state = 'current' } },
      children = {
        order = { 'ses_child' },
        by_id = { ses_child = { id = 'ses_child', parentID = 'ses_root' } },
      },
      entry_order = { 'msg_root' },
      entries_by_id = {
        msg_root = {
          id = 'msg_root',
          session_id = 'ses_root',
          kind = 'assistant',
          content = {
            {
              id = 'tool_task',
              kind = 'tool',
              name = 'task',
              state = 'completed',
              description = 'inspect child',
              child_session = { id = 'ses_child' },
            },
          },
        },
      },
      permission_requests_by_id = {},
      question_requests_by_id = {},
      files = { revision = 0 },
    })
    local connection = {
      is_ready = function()
        return true
      end,
      observe = function(_, ref)
        return ref.id == 'ses_root' and root or child
      end,
    }
    state.jobs.set_server(connection)
    state.session.set_active({ id = 'ses_root' })

    renderer.on_session_changed(nil, { id = 'ses_root' }, nil)

    local text = table.concat(vim.api.nvim_buf_get_lines(state.windows.output_buf, 0, -1, false), '\n')
    assert.is_truthy(text:find('echo child%-observation'))
    assert.equals(1, #root.watchers)
    assert.equals(1, #child.watchers)

    renderer.teardown()
    assert.is_false(root.watchers[1].active)
    assert.is_false(child.watchers[1].active)
  end)

  it('uses session usage facts for renderer stats', function()
    local root = observation({
      session = {
        id = 'ses_root',
        cost = 1.25,
        tokens = { input = 10, output = 20, reasoning = 30, cache = { read = 40, write = 50 } },
        location = { directory = '/repo' },
      },
      sync = { session = { state = 'current' }, children = { state = 'current' } },
      children = { order = {}, by_id = {} },
      entry_order = {},
      entries_by_id = {},
      permission_requests_by_id = {},
      question_requests_by_id = {},
      files = { revision = 0 },
    })
    state.jobs.set_server({
      is_ready = function()
        return true
      end,
      observe = function()
        return root
      end,
    })
    state.session.set_active({ id = 'ses_root' })

    renderer.on_session_changed(nil, { id = 'ses_root' }, nil)

    assert.equals(150, state.store.get('tokens_count'))
    assert.equals(1.25, state.store.get('cost'))
  end)

  it('falls back to the latest entry when session usage facts are absent', function()
    local root = observation({
      session = { id = 'ses_root', location = { directory = '/repo' } },
      sync = { session = { state = 'current' }, children = { state = 'current' } },
      children = { order = {}, by_id = {} },
      entry_order = { 'msg_old', 'msg_latest' },
      entries_by_id = {
        msg_old = {
          id = 'msg_old',
          session_id = 'ses_root',
          kind = 'assistant',
          cost = 0.5,
          tokens = { input = 1, output = 2, reasoning = 3, cache = { read = 4, write = 5 } },
          content = {},
        },
        msg_latest = {
          id = 'msg_latest',
          session_id = 'ses_root',
          kind = 'assistant',
          cost = 2.5,
          tokens = { input = 10, output = 20, reasoning = 30, cache = { read = 40, write = 50 } },
          content = {},
        },
      },
      permission_requests_by_id = {},
      question_requests_by_id = {},
      files = { revision = 0 },
    })
    state.jobs.set_server({
      is_ready = function()
        return true
      end,
      observe = function()
        return root
      end,
    })
    state.session.set_active({ id = 'ses_root' })
    renderer.on_session_changed(nil, { id = 'ses_root' }, nil)

    assert.equals(150, state.store.get('tokens_count'))
    assert.equals(2.5, state.store.get('cost'))
  end)

  it('keeps completed stats while a V1 assistant message reports zero usage', function()
    local root = observation({
      session = { id = 'ses_root', location = { directory = '/repo' } },
      sync = { session = { state = 'current' }, children = { state = 'current' } },
      children = { order = {}, by_id = {} },
      entry_order = { 'msg_done' },
      entries_by_id = {
        msg_done = {
          id = 'msg_done',
          session_id = 'ses_root',
          kind = 'assistant',
          cost = 1.25,
          tokens = { input = 10, output = 20, reasoning = 30, cache = { read = 40, write = 50 } },
          content = {},
        },
        msg_streaming = {
          id = 'msg_streaming',
          session_id = 'ses_root',
          kind = 'assistant',
          cost = 0,
          tokens = { input = 0, output = 0, reasoning = 0, cache = { read = 0, write = 0 } },
          content = {},
        },
      },
      permission_requests_by_id = {},
      question_requests_by_id = {},
      files = { revision = 0 },
    })
    state.jobs.set_server({
      is_ready = function()
        return true
      end,
      observe = function()
        return root
      end,
    })
    state.session.set_active({ id = 'ses_root' })
    vim.wait(100, function()
      return false
    end)

    renderer.on_session_changed(nil, { id = 'ses_root' }, nil)

    assert.equals(150, state.store.get('tokens_count'))
    assert.equals(1.25, state.store.get('cost'))

    root.read().entry_order = { 'msg_done', 'msg_streaming' }
    root.watchers[1].changed(root, 'messages')
    vim.wait(100, function()
      return false
    end)

    assert.equals(150, state.store.get('tokens_count'))
    assert.equals(1.25, state.store.get('cost'))
  end)
end)

describe('renderer flush formatter context', function()
  local formatter
  local reference_facts
  local symbol_snapshot
  local format_stub
  local refs_stub
  local files_stub
  local cycle_stub

  before_each(function()
    helpers.replay_setup()
    ctx:reset()
    formatter = require('opencode.ui.formatter')
    reference_facts = require('opencode.ui.reference_facts')
    symbol_snapshot = require('opencode.ui.symbol_snapshot')
  end)

  after_each(function()
    if format_stub then
      format_stub:revert()
    end
    if refs_stub then
      refs_stub:revert()
    end
    if files_stub then
      files_stub:revert()
    end
    if cycle_stub then
      cycle_stub:revert()
    end
    ctx:reset()
    if state.windows then
      require('opencode.ui.ui').close_windows(state.windows)
    end
  end)

  it('creates one symbol cycle and shares it across formatted parts', function()
    local Output = require('opencode.ui.output')
    local cycle = { id = 'cycle_1' }
    local contexts = {}

    refs_stub = stub(reference_facts, 'current_refs').returns({})
    files_stub = stub(reference_facts, 'available_files').returns({ '/repo/src/ok.lua' })
    cycle_stub = stub(symbol_snapshot, 'new_cycle').returns(cycle)
    format_stub = stub(formatter, 'format_part').invokes(function(_, _, _, context)
      contexts[#contexts + 1] = context
      local output = Output.new()
      output:add_line('formatted')
      return output
    end)

    local message = {
      id = 'msg_1',
      kind = 'assistant',
      session_id = 'ses_1',
      content = {
        { id = 'part_1', kind = 'text', text = 'one' },
        { id = 'part_2', kind = 'text', text = 'two' },
      },
    }
    ctx.entries = { message }
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.content[1], message.id, message.content[1].id)
    ctx.render_state:set_part(message.content[2], message.id, message.content[2].id)
    ctx.pending.dirty_part_order = { 'part_1', 'part_2' }
    ctx.pending.dirty_parts = { part_1 = 'msg_1', part_2 = 'msg_1' }

    flush.flush()

    assert.stub(cycle_stub).was_called(1)
    assert.equal(2, #contexts)
    assert.is_true(contexts[1].interactive)
    assert.is_function(contexts[1].get_child_parts)
    assert.is_nil(contexts[1].get_child_parts('missing_child'))
    assert.are.equal(cycle, contexts[1].symbol_cycle)
    assert.are.equal(contexts[1].symbol_cycle, contexts[2].symbol_cycle)
  end)
end)
