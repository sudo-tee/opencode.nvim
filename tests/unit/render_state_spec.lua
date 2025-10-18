local RenderState = require('opencode.ui.render_state')
local state = require('opencode.state')

describe('RenderState', function()
  local render_state

  before_each(function()
    render_state = RenderState.new()
    state.messages = {}
  end)

  after_each(function()
    state.messages = {}
  end)

  describe('new and reset', function()
    it('creates a new instance', function()
      assert.is_not_nil(render_state)
      assert.is_table(render_state._messages)
      assert.is_table(render_state._parts)
      assert.is_table(render_state._line_index)
      assert.is_false(render_state._line_index_valid)
    end)

    it('resets to empty state', function()
      render_state._messages = { test = true }
      render_state._parts = { test = true }
      render_state._line_index_valid = true
      render_state:reset()
      assert.is_true(vim.tbl_isempty(render_state._messages))
      assert.is_true(vim.tbl_isempty(render_state._parts))
      assert.is_true(vim.tbl_isempty(render_state._line_index.line_to_part))
      assert.is_true(vim.tbl_isempty(render_state._line_index.line_to_message))
      assert.is_false(render_state._line_index_valid)
    end)
  end)

  describe('set_message', function()
    it('sets a new message', function()
      local msg = { id = 'msg1', content = 'test' }
      render_state:set_message('msg1', msg, 1, 3)

      local result = render_state:get_message('msg1')
      assert.is_not_nil(result)
      assert.equals(msg, result.message)
      assert.equals(1, result.line_start)
      assert.equals(3, result.line_end)
    end)

    it('updates line index for message', function()
      local msg = { id = 'msg1' }
      render_state:set_message('msg1', msg, 5, 7)

      assert.is_false(render_state._line_index_valid)

      local result = render_state:get_message_at_line(6)
      assert.is_not_nil(result)
      assert.equals('msg1', result.message.id)
    end)

    it('updates existing message', function()
      local msg1 = { id = 'msg1', content = 'test' }
      local msg2 = { id = 'msg1', content = 'updated' }
      render_state:set_message('msg1', msg1, 1, 2)
      render_state:set_message('msg1', msg2, 3, 5)

      local result = render_state:get_message('msg1')
      assert.equals(msg2, result.message)
      assert.equals(3, result.line_start)
      assert.equals(5, result.line_end)
    end)
  end)

  describe('set_part', function()
    it('sets a new part', function()
      local part = { id = 'part1', content = 'test' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local result = render_state:get_part('part1')
      assert.is_not_nil(result)
      assert.equals(part, result.part)
      assert.equals('msg1', result.message_id)
      assert.equals(10, result.line_start)
      assert.equals(15, result.line_end)
    end)

    it('updates line index for part', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 20, 22)

      assert.is_false(render_state._line_index_valid)

      local result = render_state:get_part_at_line(21)
      assert.is_not_nil(result)
      assert.equals('part1', result.part.id)
    end)

    it('initializes actions array', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 1, 2)

      local result = render_state:get_part('part1')
      assert.is_table(result.actions)
      assert.equals(0, #result.actions)
    end)
  end)

  describe('get_part_at_line', function()
    it('returns part at line', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local result = render_state:get_part_at_line(12)
      assert.is_not_nil(result)
      assert.equals('part1', result.part.id)
    end)

    it('returns nil for line without part', function()
      local result = render_state:get_part_at_line(100)
      assert.is_nil(result)
    end)
  end)

  describe('get_message_at_line', function()
    it('returns message at line', function()
      local msg = { id = 'msg1' }
      render_state:set_message('msg1', msg, 5, 7)

      local result = render_state:get_message_at_line(6)
      assert.is_not_nil(result)
      assert.equals('msg1', result.message.id)
    end)

    it('returns nil for line without message', function()
      local result = render_state:get_message_at_line(100)
      assert.is_nil(result)
    end)
  end)

  describe('get_part_by_call_id', function()
    it('finds part by call ID', function()
      local msg = {
        id = 'msg1',
        parts = {
          { id = 'part1', callID = 'call1' },
          { id = 'part2', callID = 'call2' },
        },
      }
      render_state:set_message('msg1', msg)

      local part_id = render_state:get_part_by_call_id('call2', 'msg1')
      assert.equals('part2', part_id)
    end)

    it('returns nil when call ID not found', function()
      local msg = { id = 'msg1', parts = {} }
      render_state:set_message('msg1', msg)

      local part_id = render_state:get_part_by_call_id('nonexistent', 'msg1')
      assert.is_nil(part_id)
    end)
  end)

  describe('actions', function()
    it('adds actions to part', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local actions = {
        { type = 'action1', display_line = 11 },
        { type = 'action2', display_line = 12 },
      }
      render_state:add_actions('part1', actions)

      local result = render_state:get_part('part1')
      assert.equals(2, #result.actions)
      assert.equals('action1', result.actions[1].type)
    end)

    it('adds actions with offset', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local actions = {
        { type = 'action1', display_line = 5, range = { from = 5, to = 7 } },
      }
      render_state:add_actions('part1', actions, 10)

      local result = render_state:get_part('part1')
      assert.equals(15, result.actions[1].display_line)
      assert.equals(15, result.actions[1].range.from)
      assert.equals(17, result.actions[1].range.to)
    end)

    it('clears actions for part', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      render_state:add_actions('part1', { { type = 'action1' } })
      render_state:clear_actions('part1')

      local result = render_state:get_part('part1')
      assert.equals(0, #result.actions)
    end)

    it('gets actions at line', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local actions = {
        { type = 'action1', range = { from = 11, to = 13 } },
        { type = 'action2', range = { from = 14, to = 16 } },
      }
      render_state:add_actions('part1', actions)

      local line_actions = render_state:get_actions_at_line(12)
      assert.equals(1, #line_actions)
      assert.equals('action1', line_actions[1].type)
    end)

    it('gets all actions from all parts', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 20, 25)

      render_state:add_actions('part1', { { type = 'action1' } })
      render_state:add_actions('part2', { { type = 'action2' } })

      local all_actions = render_state:get_all_actions()
      assert.equals(2, #all_actions)
    end)
  end)

  describe('update_part_lines', function()
    before_each(function()
      state.messages = {
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      }
    end)

    it('updates part line positions', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      local success = render_state:update_part_lines('part1', 10, 20)
      assert.is_true(success)

      local result = render_state:get_part('part1')
      assert.equals(10, result.line_start)
      assert.equals(20, result.line_end)
    end)

    it('shifts subsequent content when expanding', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 16, 20)

      render_state:update_part_lines('part1', 10, 18)

      local result2 = render_state:get_part('part2')
      assert.equals(19, result2.line_start)
      assert.equals(23, result2.line_end)
    end)

    it('shifts subsequent content when shrinking', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 16, 20)

      render_state:update_part_lines('part1', 10, 12)

      local result2 = render_state:get_part('part2')
      assert.equals(13, result2.line_start)
      assert.equals(17, result2.line_end)
    end)

    it('returns false for non-existent part', function()
      local success = render_state:update_part_lines('nonexistent', 10, 20)
      assert.is_false(success)
    end)
  end)

  describe('remove_part', function()
    before_each(function()
      state.messages = {
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      }
    end)

    it('removes part and shifts subsequent content', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 16, 20)

      local success = render_state:remove_part('part1')
      assert.is_true(success)

      assert.is_nil(render_state:get_part('part1'))

      local result2 = render_state:get_part('part2')
      assert.equals(10, result2.line_start)
      assert.equals(14, result2.line_end)
    end)

    it('clears line index for removed part', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      render_state:remove_part('part1')

      assert.is_nil(render_state:get_part_at_line(10))
      assert.is_nil(render_state:get_part_at_line(15))
    end)

    it('returns false for non-existent part', function()
      local success = render_state:remove_part('nonexistent')
      assert.is_false(success)
    end)
  end)

  describe('remove_message', function()
    before_each(function()
      state.messages = {
        {
          info = { id = 'msg1' },
        },
        {
          info = { id = 'msg2' },
        },
      }
    end)

    it('removes message and shifts subsequent content', function()
      local msg1 = { id = 'msg1' }
      local msg2 = { id = 'msg2' }
      render_state:set_message('msg1', msg1, 1, 5)
      render_state:set_message('msg2', msg2, 6, 10)

      local success = render_state:remove_message('msg1')
      assert.is_true(success)

      assert.is_nil(render_state:get_message('msg1'))

      local result2 = render_state:get_message('msg2')
      assert.equals(1, result2.line_start)
      assert.equals(5, result2.line_end)
    end)

    it('clears line index for removed message', function()
      local msg = { id = 'msg1' }
      render_state:set_message('msg1', msg, 1, 5)

      render_state:remove_message('msg1')

      assert.is_nil(render_state:get_message_at_line(1))
      assert.is_nil(render_state:get_message_at_line(5))
    end)

    it('returns false for non-existent message', function()
      local success = render_state:remove_message('nonexistent')
      assert.is_false(success)
    end)
  end)

  describe('shift_all', function()
    before_each(function()
      state.messages = {
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      }
    end)

    it('does nothing when delta is 0', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      render_state:shift_all(20, 0)

      local result = render_state:get_part('part1')
      assert.equals(10, result.line_start)
      assert.equals(15, result.line_end)
    end)

    it('shifts content at or after from_line', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 20, 25)

      render_state:shift_all(20, 5)

      local result1 = render_state:get_part('part1')
      assert.equals(10, result1.line_start)
      assert.equals(15, result1.line_end)

      local result2 = render_state:get_part('part2')
      assert.equals(25, result2.line_start)
      assert.equals(30, result2.line_end)
    end)

    it('shifts actions with parts', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 20, 25)
      render_state:add_actions('part1', {
        { type = 'action1', display_line = 22, range = { from = 21, to = 23 } },
      })

      render_state:shift_all(20, 10)

      local result = render_state:get_part('part1')
      assert.equals(32, result.actions[1].display_line)
      assert.equals(31, result.actions[1].range.from)
      assert.equals(33, result.actions[1].range.to)
    end)

    it('does not rebuild index when nothing shifted', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      render_state._line_index_valid = true

      render_state:shift_all(100, 5)

      assert.is_true(render_state._line_index_valid)
    end)

    it('invalidates index when content shifted', function()
      local part = { id = 'part1' }
      render_state:set_part('part1', part, 'msg1', 10, 15)

      render_state._line_index_valid = true

      render_state:shift_all(10, 5)

      assert.is_false(render_state._line_index_valid)
    end)

    it('exits early when content found before from_line', function()
      local part1 = { id = 'part1' }
      local part2 = { id = 'part2' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)
      render_state:set_part('part2', part2, 'msg1', 50, 55)

      render_state:shift_all(50, 10)

      local result1 = render_state:get_part('part1')
      assert.equals(10, result1.line_start)

      local result2 = render_state:get_part('part2')
      assert.equals(60, result2.line_start)
    end)
  end)

  describe('update_part_data', function()
    it('updates part reference', function()
      local part1 = { id = 'part1', content = 'original' }
      local part2 = { id = 'part1', content = 'updated' }
      render_state:set_part('part1', part1, 'msg1', 10, 15)

      render_state:update_part_data('part1', part2)

      local result = render_state:get_part('part1')
      assert.equals('updated', result.part.content)
    end)

    it('does nothing for non-existent part', function()
      render_state:update_part_data('nonexistent', { id = 'test' })
    end)
  end)
end)
