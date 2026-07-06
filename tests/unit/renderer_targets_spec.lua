local ctx = require('opencode.ui.renderer.ctx')
local renderer = require('opencode.ui.renderer')
local flush = require('opencode.ui.renderer.flush')
local stub = require('luassert.stub')
local helpers = require('tests.helpers')
local state = require('opencode.state')

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
    ctx.render_state:set_part({ id = 'part1', messageID = 'msg1' }, 0, 0)
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
    files_stub = stub(reference_facts, 'current_files').returns({ '/repo/src/ok.lua' })
    cycle_stub = stub(symbol_snapshot, 'new_cycle').returns(cycle)
    format_stub = stub(formatter, 'format_part').invokes(function(_, _, _, context)
      contexts[#contexts + 1] = context
      local output = Output.new()
      output:add_line('formatted')
      return output
    end)

    local message = {
      info = { id = 'msg_1', role = 'assistant', sessionID = 'ses_1' },
      parts = {
        { id = 'part_1', messageID = 'msg_1', sessionID = 'ses_1', type = 'text', text = 'one' },
        { id = 'part_2', messageID = 'msg_1', sessionID = 'ses_1', type = 'text', text = 'two' },
      },
    }
    ctx.render_state:set_message(message)
    ctx.render_state:set_part(message.parts[1], 1, 1)
    ctx.render_state:set_part(message.parts[2], 2, 2)
    ctx.render_state:upsert_child_session_part('child_1', { id = 'child_part', type = 'tool' })
    ctx.pending.dirty_part_order = { 'part_1', 'part_2' }
    ctx.pending.dirty_parts = { part_1 = 'msg_1', part_2 = 'msg_1' }

    flush.flush()

    assert.stub(cycle_stub).was_called(1)
    assert.equal(2, #contexts)
    assert.is_true(contexts[1].interactive)
    assert.is_function(contexts[1].get_child_parts)
    assert.are.same(ctx.render_state:get_child_session_parts('child_1'), contexts[1].get_child_parts('child_1'))
    assert.are.equal(cycle, contexts[1].symbol_cycle)
    assert.are.equal(contexts[1].symbol_cycle, contexts[2].symbol_cycle)
  end)
end)
