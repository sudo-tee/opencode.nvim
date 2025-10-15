local MessageMap = require('opencode.ui.message_map')
local assert = require('luassert')

describe('MessageMap', function()
  local message_map

  before_each(function()
    message_map = MessageMap.new()
  end)

  describe('new', function()
    it('creates a new MessageMap instance', function()
      local map = MessageMap.new()
      assert.is_not_nil(map)
      assert.are.equal('table', type(map._message_lookup))
      assert.are.equal('table', type(map._part_lookup))
      assert.are.equal('table', type(map._call_id_lookup))
    end)
  end)

  describe('reset', function()
    it('clears all lookup tables', function()
      message_map:add_message('msg1', 1)
      message_map:add_part('part1', 1, 1, 'call1')

      message_map:reset()

      assert.are.equal(0, vim.tbl_count(message_map._message_lookup))
      assert.are.equal(0, vim.tbl_count(message_map._part_lookup))
      assert.are.equal(0, vim.tbl_count(message_map._call_id_lookup))
    end)
  end)

  describe('add_message', function()
    it('adds message to lookup table', function()
      message_map:add_message('msg1', 1)

      assert.are.equal(1, message_map:get_message_index('msg1'))
    end)

    it('overwrites existing message mapping', function()
      message_map:add_message('msg1', 1)
      message_map:add_message('msg1', 2)

      assert.are.equal(2, message_map:get_message_index('msg1'))
    end)
  end)

  describe('add_part', function()
    it('adds part to lookup tables', function()
      message_map:add_part('part1', 1, 1, 'call1')

      local location = message_map:get_part_location('part1')
      assert.are.equal(1, location.message_idx)
      assert.are.equal(1, location.part_idx)
      assert.are.equal('part1', message_map:get_part_id_by_call_id('call1'))
    end)

    it('adds part without call_id', function()
      message_map:add_part('part1', 1, 1)

      local location = message_map:get_part_location('part1')
      assert.are.equal(1, location.message_idx)
      assert.are.equal(1, location.part_idx)
      assert.is_nil(message_map:get_part_id_by_call_id('call1'))
    end)
  end)

  describe('has_part', function()
    it('returns true for existing part', function()
      message_map:add_part('part1', 1, 1)
      assert.is_true(message_map:has_part('part1'))
    end)

    it('returns false for non-existing part', function()
      assert.is_false(message_map:has_part('nonexistent'))
    end)
  end)

  describe('get_message_by_id', function()
    it('returns message wrapper and index', function()
      local messages = {
        { info = { id = 'msg1' }, parts = {} },
      }
      message_map:add_message('msg1', 1)

      local msg_wrapper, msg_idx = message_map:get_message_by_id('msg1', messages)
      assert.are.equal(messages[1], msg_wrapper)
      assert.are.equal(1, msg_idx)
    end)

    it('returns nil for non-existing message', function()
      local messages = {}
      local msg_wrapper, msg_idx = message_map:get_message_by_id('nonexistent', messages)
      assert.is_nil(msg_wrapper)
      assert.is_nil(msg_idx)
    end)
  end)

  describe('get_part_by_id', function()
    it('returns part, message wrapper, and indices', function()
      local messages = {
        {
          info = { id = 'msg1' },
          parts = { { id = 'part1', text = 'test' } },
        },
      }
      message_map:add_message('msg1', 1)
      message_map:add_part('part1', 1, 1)

      local part, msg_wrapper, msg_idx, part_idx = message_map:get_part_by_id('part1', messages)
      assert.are.equal(messages[1].parts[1], part)
      assert.are.equal(messages[1], msg_wrapper)
      assert.are.equal(1, msg_idx)
      assert.are.equal(1, part_idx)
    end)

    it('returns nil for non-existing part', function()
      local messages = {}
      local part, msg_wrapper, msg_idx, part_idx = message_map:get_part_by_id('nonexistent', messages)
      assert.is_nil(part)
      assert.is_nil(msg_wrapper)
      assert.is_nil(msg_idx)
      assert.is_nil(part_idx)
    end)
  end)

  describe('update_part', function()
    it('updates existing part in messages array', function()
      local messages = {
        {
          info = { id = 'msg1' },
          parts = { { id = 'part1', text = 'old' } },
        },
      }
      message_map:add_part('part1', 1, 1)

      local new_part = { id = 'part1', text = 'new', callID = 'call1' }
      local part_idx = message_map:update_part('part1', new_part, messages)

      assert.are.equal(1, part_idx)
      assert.are.equal('new', messages[1].parts[1].text)
      assert.are.equal('part1', message_map:get_part_id_by_call_id('call1'))
    end)

    it('returns nil for non-existing part', function()
      local messages = {}
      local part_idx = message_map:update_part('nonexistent', {}, messages)
      assert.is_nil(part_idx)
    end)
  end)

  describe('update_call_id', function()
    it('updates call ID mapping', function()
      message_map:update_call_id('call1', 'part1')
      assert.are.equal('part1', message_map:get_part_id_by_call_id('call1'))
    end)
  end)

  describe('remove_part', function()
    it('removes part from lookup tables and messages array', function()
      local messages = {
        {
          info = { id = 'msg1' },
          parts = { { id = 'part1' }, { id = 'part2' } },
        },
      }
      message_map:add_part('part1', 1, 1, 'call1')
      message_map:add_part('part2', 1, 2, 'call2')

      message_map:remove_part('part1', 'call1', messages)

      assert.is_false(message_map:has_part('part1'))
      assert.is_nil(message_map:get_part_id_by_call_id('call1'))
      assert.are.equal(1, #messages[1].parts)
      assert.are.equal('part2', messages[1].parts[1].id)

      local location = message_map:get_part_location('part2')
      assert.are.equal(1, location.part_idx)
    end)
  end)

  describe('remove_message', function()
    it('removes message and all its parts from lookup tables and array', function()
      local messages = {
        { info = { id = 'msg1' }, parts = { { id = 'part1', callID = 'call1' } } },
        { info = { id = 'msg2' }, parts = { { id = 'part2', callID = 'call2' } } },
      }
      message_map:add_message('msg1', 1)
      message_map:add_message('msg2', 2)
      message_map:add_part('part1', 1, 1, 'call1')
      message_map:add_part('part2', 2, 1, 'call2')

      message_map:remove_message('msg1', messages)

      assert.is_nil(message_map:get_message_index('msg1'))
      assert.is_false(message_map:has_part('part1'))
      assert.is_nil(message_map:get_part_id_by_call_id('call1'))
      assert.are.equal(1, #messages)
      assert.are.equal('msg2', messages[1].info.id)

      assert.are.equal(1, message_map:get_message_index('msg2'))
      local location = message_map:get_part_location('part2')
      assert.are.equal(1, location.message_idx)
    end)
  end)

  describe('hydrate', function()
    it('builds lookup tables from existing messages array', function()
      local messages = {
        {
          info = { id = 'msg1' },
          parts = {
            { id = 'part1', callID = 'call1' },
            { id = 'part2' },
          },
        },
        {
          info = { id = 'msg2' },
          parts = {
            { id = 'part3', callID = 'call3' },
          },
        },
      }

      message_map:hydrate(messages)

      assert.are.equal(1, message_map:get_message_index('msg1'))
      assert.are.equal(2, message_map:get_message_index('msg2'))

      local loc1 = message_map:get_part_location('part1')
      assert.are.equal(1, loc1.message_idx)
      assert.are.equal(1, loc1.part_idx)

      local loc2 = message_map:get_part_location('part2')
      assert.are.equal(1, loc2.message_idx)
      assert.are.equal(2, loc2.part_idx)

      local loc3 = message_map:get_part_location('part3')
      assert.are.equal(2, loc3.message_idx)
      assert.are.equal(1, loc3.part_idx)

      assert.are.equal('part1', message_map:get_part_id_by_call_id('call1'))
      assert.are.equal('part3', message_map:get_part_id_by_call_id('call3'))
    end)

    it('resets before building lookups', function()
      message_map:add_message('old', 1)

      local messages = {
        { info = { id = 'new' }, parts = {} },
      }

      message_map:hydrate(messages)

      assert.is_nil(message_map:get_message_index('old'))
      assert.are.equal(1, message_map:get_message_index('new'))
    end)

    it('handles messages without parts', function()
      local messages = {
        { info = { id = 'msg1' } },
      }

      message_map:hydrate(messages)

      assert.are.equal(1, message_map:get_message_index('msg1'))
    end)

    it('handles messages without info', function()
      local messages = {
        { parts = {} },
      }

      assert.has_no.errors(function()
        message_map:hydrate(messages)
      end)
    end)
  end)

  describe('complex scenarios', function()
    it('handles multiple operations correctly', function()
      local messages = {}

      table.insert(messages, { info = { id = 'msg1' }, parts = {} })
      message_map:add_message('msg1', 1)

      table.insert(messages[1].parts, { id = 'part1', text = 'first' })
      message_map:add_part('part1', 1, 1, 'call1')

      table.insert(messages[1].parts, { id = 'part2', text = 'second' })
      message_map:add_part('part2', 1, 2, 'call2')

      table.insert(messages, { info = { id = 'msg2' }, parts = {} })
      message_map:add_message('msg2', 2)

      table.insert(messages[2].parts, { id = 'part3', text = 'third' })
      message_map:add_part('part3', 2, 1, 'call3')

      assert.are.equal(2, #messages)
      assert.are.equal(2, #messages[1].parts)
      assert.are.equal(1, #messages[2].parts)

      local part, msg_wrapper, msg_idx, part_idx = message_map:get_part_by_id('part2', messages)
      assert.are.equal('second', part.text)
      assert.are.equal(1, msg_idx)
      assert.are.equal(2, part_idx)

      message_map:remove_part('part1', 'call1', messages)

      assert.are.equal(1, #messages[1].parts)
      assert.are.equal('part2', messages[1].parts[1].id)

      local updated_location = message_map:get_part_location('part2')
      assert.are.equal(1, updated_location.part_idx)
    end)
  end)
end)

