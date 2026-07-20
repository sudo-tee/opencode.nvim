local RenderState = require('opencode.ui.render_state')
local state = require('opencode.state')

describe('RenderState', function()
  local render_state

  before_each(function()
    render_state = RenderState.new()
    state.renderer.set_messages({})
  end)

  after_each(function()
    state.renderer.set_messages({})
  end)

  describe('new and reset', function()
    it('creates a new instance', function()
      assert.is_not_nil(render_state)
      assert.is_table(render_state._messages)
      assert.is_table(render_state._parts)
      assert.is_table(render_state._part_ranges)
      assert.is_false(render_state._ranges_valid)
    end)

    it('resets to empty state', function()
      render_state._messages = { test = true }
      render_state._parts = { test = true }
      render_state._ranges_valid = true
      render_state:reset()
      assert.is_true(vim.tbl_isempty(render_state._messages))
      assert.is_true(vim.tbl_isempty(render_state._parts))
      assert.is_true(vim.tbl_isempty(render_state._part_ranges))
      assert.is_true(vim.tbl_isempty(render_state._message_ranges))
      assert.is_false(render_state._ranges_valid)
    end)
  end)

  describe('set_message', function()
    it('sets a new message', function()
      local msg = { info = { id = 'msg1' }, content = 'test' }
      render_state:set_message(msg, 1, 3)

      local result = render_state:get_message('msg1')
      assert.is_not_nil(result)
      assert.equals(msg, result.message)
      assert.equals(1, result.line_start)
      assert.equals(3, result.line_end)
    end)

    it('updates line index for message', function()
      local msg = { info = { id = 'msg1' } }
      render_state:set_message(msg, 5, 7)

      assert.is_false(render_state._ranges_valid)

      local result = render_state:get_message_at_line(6)
      assert.is_not_nil(result)
      assert.equals('msg1', result.message.info.id)
    end)

    it('updates existing message', function()
      local msg1 = { info = { id = 'msg1' }, content = 'test' }
      local msg2 = { info = { id = 'msg1' }, content = 'updated' }
      render_state:set_message(msg1, 1, 2)
      render_state:set_message(msg2, 3, 5)

      local result = render_state:get_message('msg1')
      assert.equals(msg2, result.message)
      assert.equals(3, result.line_start)
      assert.equals(5, result.line_end)
    end)
  end)

  describe('set_part', function()
    it('sets a new part', function()
      local part = { id = 'part1', messageID = 'msg1', content = 'test' }
      render_state:set_part(part, 10, 15)

      local result = render_state:get_part('part1')
      assert.is_not_nil(result)
      assert.equals(part, result.part)
      assert.equals('msg1', result.message_id)
      assert.equals(10, result.line_start)
      assert.equals(15, result.line_end)
    end)

    it('updates line index for part', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 20, 22)

      assert.is_false(render_state._ranges_valid)

      local result = render_state:get_part_at_line(21)
      assert.is_not_nil(result)
      assert.equals('part1', result.part.id)
    end)

    it('initializes actions array', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 1, 2)

      local result = render_state:get_part('part1')
      assert.is_table(result.actions)
      assert.equals(0, #result.actions)
    end)

    it('indexes task parts by child session ID', function()
      local part = {
        id = 'part1',
        messageID = 'msg1',
        tool = 'task',
        state = {
          metadata = {
            sessionId = 'child-1',
          },
        },
      }

      render_state:set_part(part, 1, 2)

      assert.equals('part1', render_state:get_task_part_by_child_session('child-1'))
    end)

    it('stores child session parts independently', function()
      local part = {
        id = 'child-part-1',
        messageID = 'msg-child',
        sessionID = 'child-1',
        tool = 'question',
      }

      render_state:upsert_child_session_part('child-1', part)

      local child_parts = render_state:get_child_session_parts('child-1')
      assert.equals(1, #child_parts)
      assert.equals('child-part-1', child_parts[1].id)
    end)
  end)

  describe('get_part_at_line', function()
    it('returns part at line', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

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
      local msg = { info = { id = 'msg1' } }
      render_state:set_message(msg, 5, 7)

      local result = render_state:get_message_at_line(6)
      assert.is_not_nil(result)
      assert.equals('msg1', result.message.info.id)
    end)

    it('returns nil for line without message', function()
      local result = render_state:get_message_at_line(100)
      assert.is_nil(result)
    end)
  end)

  describe('get_part_by_call_id', function()
    it('finds part by call ID', function()
      local msg = {
        info = { id = 'msg1' },
        parts = {
          { id = 'part1', callID = 'call1' },
          { id = 'part2', callID = 'call2' },
        },
      }
      render_state:set_message(msg)

      local part_id = render_state:get_part_by_call_id('call2', 'msg1')
      assert.equals('part2', part_id)
    end)

    it('returns nil when call ID not found', function()
      local msg = { info = { id = 'msg1' }, parts = {} }
      render_state:set_message(msg)

      local part_id = render_state:get_part_by_call_id('nonexistent', 'msg1')
      assert.is_nil(part_id)
    end)
  end)

  describe('actions', function()
    it('adds actions to part', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

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
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

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
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state:add_actions('part1', { { type = 'action1' } })
      render_state:clear_actions('part1')

      local result = render_state:get_part('part1')
      assert.equals(0, #result.actions)
    end)

    it('gets actions at line', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      local actions = {
        { type = 'action1', range = { from = 11, to = 13 } },
        { type = 'action2', range = { from = 14, to = 16 } },
      }
      render_state:add_actions('part1', actions)

      local line_actions = render_state:get_actions_at_line(12)
      assert.equals(1, #line_actions)
      assert.equals('action1', line_actions[1].type)
    end)

    it('owns one R/C/F set across an actionable user message block', function()
      local message = {
        info = { id = 'msg-user', role = 'user' },
        parts = {
          { id = 'text-part', messageID = 'msg-user', type = 'text', text = 'prompt' },
          { id = 'file-part', messageID = 'msg-user', type = 'file', filename = 'file.lua' },
        },
      }
      render_state:set_message(message, 20, 21)
      render_state:set_part(message.parts[1], 22, 24)
      render_state:set_part(message.parts[2], 25, 26)

      local rendered = render_state:get_message('msg-user')
      assert.equals(3, #rendered.actions)
      assert.same({ from = 20, to = 26 }, rendered.actions[1].range)
      assert.same(
        { 'undo', 'copy_message', 'fork_session' },
        vim.tbl_map(function(action)
          return action.type
        end, rendered.actions)
      )

      for line = 20, 26 do
        local actions = render_state:get_actions_at_line(line)
        assert.equals(3, #actions)
        assert.same({ 'msg-user' }, actions[1].args)
      end
    end)

    it('refreshes message actions after a header expansion shifts its parts', function()
      local message = {
        info = { id = 'msg-user', role = 'user' },
        parts = {
          { id = 'text-part', messageID = 'msg-user', type = 'text', text = 'prompt' },
          { id = 'file-part', messageID = 'msg-user', type = 'file', filename = 'file.lua' },
        },
      }
      render_state:set_message(message, 10, 11)
      render_state:set_part(message.parts[1], 12, 13)
      render_state:set_part(message.parts[2], 14, 15)

      render_state:set_message(message, 10, 13)
      render_state:shift_all(12, 2)

      local action = render_state:get_message('msg-user').actions[1]
      assert.same({ from = 10, to = 17 }, action.range)
      assert.same({ 'msg-user' }, render_state:get_actions_at_line(17)[1].args)
    end)

    it('keeps message actions within the block after the closest header', function()
      local user_one = {
        info = { id = 'user-one', role = 'user' },
        parts = { { id = 'user-one-text', messageID = 'user-one', type = 'text', text = 'first' } },
      }
      local assistant = {
        info = { id = 'assistant', role = 'assistant' },
        parts = { { id = 'assistant-text', messageID = 'assistant', type = 'text', text = 'reply' } },
      }
      local user_two = {
        info = { id = 'user-two', role = 'user' },
        parts = { { id = 'user-two-text', messageID = 'user-two', type = 'text', text = 'second' } },
      }
      render_state:set_message(user_one, 10, 11)
      render_state:set_part(user_one.parts[1], 12, 14)
      render_state:set_message(assistant, 15, 16)
      render_state:set_part(assistant.parts[1], 17, 18)
      render_state:set_message(user_two, 19, 20)
      render_state:set_part(user_two.parts[1], 21, 23)

      assert.same({ 'user-one' }, render_state:get_actions_at_line(10)[1].args)
      assert.same({ 'user-one' }, render_state:get_actions_at_line(14)[1].args)
      assert.same({}, render_state:get_actions_at_line(17))
      assert.same({ 'user-two' }, render_state:get_actions_at_line(19)[1].args)
      assert.same({ 'user-two' }, render_state:get_actions_at_line(23)[1].args)
    end)

    it('requires a non-synthetic non-empty user text part for message actions', function()
      for _, message in ipairs({
        { info = { id = 'assistant', role = 'assistant' }, parts = { { type = 'text', text = 'text' } } },
        { info = { id = 'system', role = 'system' }, parts = { { type = 'text', text = 'text' } } },
        { info = { id = '', role = 'user' }, parts = { { type = 'text', text = 'text' } } },
        { info = { id = 'synthetic', role = 'user' }, parts = { { type = 'text', text = 'text', synthetic = true } } },
        { info = { id = 'empty', role = 'user' }, parts = { { type = 'text', text = '  ' } } },
      }) do
        render_state:set_message(message, 30, 31)
        assert.same({}, render_state:get_actions_at_line(30))
      end
    end)

    it('gets all actions from all parts', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 20, 25)

      render_state:add_actions('part1', { { type = 'action1' } })
      render_state:add_actions('part2', { { type = 'action2' } })

      local all_actions = render_state:get_all_actions()
      assert.equals(2, #all_actions)
    end)
  end)

  describe('targets', function()
    local function target(kind, line, start_col, end_col, extra)
      local result = vim.tbl_extend('force', {
        kind = kind,
        range = {
          line = line,
          start_col = start_col,
          end_col = end_col,
        },
      }, extra or {})
      return result
    end

    before_each(function()
      render_state:set_part({ id = 'part1', messageID = 'msg1' }, 0, 2)
    end)

    it('adds and gets targets by line and column', function()
      render_state:add_targets('part1', {
        target('file', 1, 3, 12, { path = 'lua/opencode/init.lua' }),
      })

      local result = render_state:get_target_at_position(1, 3)

      assert.is_not_nil(result)
      assert.equals('file', result.kind)
      assert.equals('part1', result.part_id)
      assert.equals('msg1', result.message_id)
      assert.equals('lua/opencode/init.lua', result.path)
      assert.is_nil(render_state:get_target_at_position(1, 12))
    end)

    it('applies output line offset when adding targets', function()
      render_state:add_targets('part1', {
        target('file', 2, 0, 4, { path = 'README.md' }),
      }, 10)

      assert.is_nil(render_state:get_target_at_position(2, 1))

      local result = render_state:get_target_at_position(12, 1)
      assert.is_not_nil(result)
      assert.equals('README.md', result.path)
    end)

    it('clears all targets for a part', function()
      render_state:add_targets('part1', {
        target('file', 1, 0, 4, { path = 'README.md' }),
        target('symbol', 1, 5, 9, { token = 'setup', candidate_files = { 'README.md' } }),
      })

      render_state:clear_targets('part1')

      assert.is_nil(render_state:get_target_at_position(1, 1))
      assert.is_nil(render_state:get_target_at_position(1, 6))
    end)

    it('leaves no target after clear followed by empty add', function()
      render_state:add_targets('part1', {
        target('file', 1, 0, 4, { path = 'README.md' }),
      })

      render_state:clear_targets('part1')
      render_state:add_targets('part1', {}, 10)

      assert.is_nil(render_state:get_target_at_position(1, 1))
    end)

    it('filters targets without changing file and diff priority over symbols', function()
      render_state:add_targets('part1', {
        target('symbol', 1, 0, 10, { token = 'setup', candidate_files = { 'README.md' } }),
        target('diff', 1, 0, 10, { path = 'README.md', line = 3 }),
      })

      local result = render_state:get_target_at_position(1, 4)
      assert.equals('diff', result.kind)

      local symbol = render_state:get_target_at_position(1, 4, function(candidate)
        return candidate.kind == 'symbol'
      end)
      assert.equals('symbol', symbol.kind)
    end)

    it('moves targets with shifted parts', function()
      render_state:set_part({ id = 'part2', messageID = 'msg1' }, 3, 4)
      render_state:add_targets('part2', {
        target('file', 4, 0, 6, { path = 'later.lua' }),
      })

      render_state:shift_all(3, 5)

      assert.is_nil(render_state:get_target_at_position(4, 1))
      local shifted = render_state:get_target_at_position(9, 1)
      assert.is_not_nil(shifted)
      assert.equals('part2', shifted.part_id)
    end)

    it('moves targets when a part line range is updated', function()
      render_state:add_targets('part1', {
        target('file', 1, 0, 6, { path = 'moved.lua' }),
      })

      render_state:update_part_lines('part1', 5, 7)

      assert.is_nil(render_state:get_target_at_position(1, 1))
      local shifted = render_state:get_target_at_position(6, 1)
      assert.is_not_nil(shifted)
      assert.equals('moved.lua', shifted.path)
    end)

    it('removes targets with the removed part and shifts remaining part targets', function()
      render_state:set_part({ id = 'part2', messageID = 'msg1' }, 3, 4)
      render_state:add_targets('part1', {
        target('file', 1, 8, 14, { path = 'removed.lua' }),
      })
      render_state:add_targets('part2', {
        target('file', 4, 0, 6, { path = 'kept.lua' }),
      })

      render_state:remove_part('part1')

      assert.is_nil(render_state:get_target_at_position(1, 9))
      local shifted = render_state:get_target_at_position(1, 1)
      assert.is_not_nil(shifted)
      assert.equals('kept.lua', shifted.path)
    end)
  end)

  describe('update_part_lines', function()
    before_each(function()
      state.renderer.set_messages({
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      })
    end)

    it('updates part line positions', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      local success = render_state:update_part_lines('part1', 10, 20)
      assert.is_true(success)

      local result = render_state:get_part('part1')
      assert.equals(10, result.line_start)
      assert.equals(20, result.line_end)
    end)

    it('shifts subsequent content when expanding', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 16, 20)

      render_state:update_part_lines('part1', 10, 18)

      local result2 = render_state:get_part('part2')
      assert.equals(19, result2.line_start)
      assert.equals(23, result2.line_end)
    end)

    it('shifts subsequent content when shrinking', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 16, 20)

      render_state:update_part_lines('part1', 10, 12)

      local result2 = render_state:get_part('part2')
      assert.equals(13, result2.line_start)
      assert.equals(17, result2.line_end)
    end)

    it('returns false for non-existent part', function()
      local success = render_state:update_part_lines('nonexistent', 10, 20)
      assert.is_false(success)
    end)

    it('returns early when lines are unchanged', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)
      render_state._ranges_valid = true

      local success = render_state:update_part_lines('part1', 10, 15)

      assert.is_true(success)
      assert.is_true(render_state._ranges_valid)
    end)
  end)

  describe('remove_part', function()
    before_each(function()
      state.renderer.set_messages({
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      })
    end)

    it('removes part and shifts subsequent content', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 16, 20)

      local success = render_state:remove_part('part1')
      assert.is_true(success)

      assert.is_nil(render_state:get_part('part1'))

      local result2 = render_state:get_part('part2')
      assert.equals(10, result2.line_start)
      assert.equals(14, result2.line_end)
    end)

    it('clears line index for removed part', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state:remove_part('part1')

      assert.is_nil(render_state:get_part_at_line(10))
      assert.is_nil(render_state:get_part_at_line(15))
    end)

    it('returns false for non-existent part', function()
      local success = render_state:remove_part('nonexistent')
      assert.is_false(success)
    end)

    it('clears child session index when removing unrendered task parts', function()
      local part = {
        id = 'part1',
        messageID = 'msg1',
        tool = 'task',
        state = {
          metadata = {
            sessionId = 'child-1',
          },
        },
      }

      render_state:set_part(part)
      local success = render_state:remove_part('part1')

      assert.is_true(success)
      assert.is_nil(render_state:get_task_part_by_child_session('child-1'))
    end)
  end)

  describe('remove_message', function()
    before_each(function()
      state.renderer.set_messages({
        {
          info = { id = 'msg1' },
        },
        {
          info = { id = 'msg2' },
        },
      })
    end)

    it('removes message and shifts subsequent content', function()
      local msg1 = { info = { id = 'msg1' } }
      local msg2 = { info = { id = 'msg2' } }
      render_state:set_message(msg1, 1, 5)
      render_state:set_message(msg2, 6, 10)

      local success = render_state:remove_message('msg1')
      assert.is_true(success)

      assert.is_nil(render_state:get_message('msg1'))

      local result2 = render_state:get_message('msg2')
      assert.equals(1, result2.line_start)
      assert.equals(5, result2.line_end)
    end)

    it('clears line index for removed message', function()
      local msg = { info = { id = 'msg1' } }
      render_state:set_message(msg, 1, 5)

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
      state.renderer.set_messages({
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1' },
            { id = 'part2' },
          },
        },
      })
    end)

    it('does nothing when delta is 0', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state:shift_all(20, 0)

      local result = render_state:get_part('part1')
      assert.equals(10, result.line_start)
      assert.equals(15, result.line_end)
    end)

    it('shifts content at or after from_line', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 20, 25)

      render_state:shift_all(20, 5)

      local result1 = render_state:get_part('part1')
      assert.equals(10, result1.line_start)
      assert.equals(15, result1.line_end)

      local result2 = render_state:get_part('part2')
      assert.equals(25, result2.line_start)
      assert.equals(30, result2.line_end)
    end)

    it('shifts actions with parts', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 20, 25)
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
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state._ranges_valid = true

      render_state:shift_all(100, 5)

      assert.is_true(render_state._ranges_valid)
    end)

    it('invalidates index when content shifted', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state._ranges_valid = true

      render_state:shift_all(10, 5)

      assert.is_false(render_state._ranges_valid)
    end)

    it('exits early when content found before from_line', function()
      local part1 = { id = 'part1', messageID = 'msg1' }
      local part2 = { id = 'part2', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)
      render_state:set_part(part2, 50, 55)

      render_state:shift_all(50, 10)

      local result1 = render_state:get_part('part1')
      assert.equals(10, result1.line_start)

      local result2 = render_state:get_part('part2')
      assert.equals(60, result2.line_start)
    end)

    it('exits early when from_line is after max rendered line', function()
      local part = { id = 'part1', messageID = 'msg1' }
      render_state:set_part(part, 10, 15)

      render_state._ranges_valid = true
      render_state:shift_all(100, 5)

      local result = render_state:get_part('part1')
      assert.equals(10, result.line_start)
      assert.equals(15, result.line_end)
      assert.is_true(render_state._ranges_valid)
    end)
  end)

  describe('update_part_data', function()
    it('updates part reference', function()
      local part1 = { id = 'part1', content = 'original', messageID = 'msg1' }
      local part2 = { id = 'part1', content = 'updated', messageID = 'msg1' }
      render_state:set_part(part1, 10, 15)

      render_state:update_part_data(part2)

      local result = render_state:get_part('part1')
      assert.equals('updated', result.part.content)
    end)

    it('does nothing for non-existent part', function()
      render_state:update_part_data({ id = 'nonexistent' })
    end)

    it('updates child session index when task metadata changes', function()
      local original = {
        id = 'part1',
        content = 'original',
        messageID = 'msg1',
        tool = 'task',
        state = {
          metadata = {
            sessionId = 'child-1',
          },
        },
      }
      local updated = {
        id = 'part1',
        content = 'updated',
        messageID = 'msg1',
        tool = 'task',
        state = {
          metadata = {
            sessionId = 'child-2',
          },
        },
      }

      render_state:set_part(original, 10, 15)
      render_state:update_part_data(updated)

      assert.is_nil(render_state:get_task_part_by_child_session('child-1'))
      assert.equals('part1', render_state:get_task_part_by_child_session('child-2'))
    end)
  end)
end)
