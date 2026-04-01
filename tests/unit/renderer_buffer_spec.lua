local buffer = require('opencode.ui.renderer.buffer')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')
local stub = require('luassert.stub')

local function assert_called_before(call_order, first_name, second_name)
  local first_idx
  local second_idx

  for idx, name in ipairs(call_order) do
    if name == first_name and not first_idx then
      first_idx = idx
    end
    if name == second_name and not second_idx then
      second_idx = idx
    end
  end

  assert.is_truthy(first_idx, 'expected ' .. first_name .. ' to be called')
  assert.is_truthy(second_idx, 'expected ' .. second_name .. ' to be called')
  assert.is_true(first_idx < second_idx)
end

describe('renderer.buffer extmarks', function()
  local set_lines_stub
  local clear_extmarks_stub
  local set_extmarks_stub
  local highlight_changed_lines_stub
  local call_order

  before_each(function()
    ctx:reset()
    call_order = {}
    set_lines_stub = stub(output_window, 'set_lines').invokes(function()
      call_order[#call_order + 1] = 'set_lines'
    end)
    clear_extmarks_stub = stub(output_window, 'clear_extmarks').invokes(function()
      call_order[#call_order + 1] = 'clear_extmarks'
    end)
    set_extmarks_stub = stub(output_window, 'set_extmarks')
    highlight_changed_lines_stub = stub(output_window, 'highlight_changed_lines')
  end)

  after_each(function()
    set_lines_stub:revert()
    clear_extmarks_stub:revert()
    set_extmarks_stub:revert()
    highlight_changed_lines_stub:revert()
    ctx:reset()
  end)

  it('reapplies extmarks on the first changed line when updating a part', function()
    ctx.render_state:set_part({ id = 'part_1', messageID = 'msg_1', type = 'text' }, 10, 11)

    buffer.upsert_part_now('part_1', 'msg_1', {
      lines = { 'alpha', 'gamma' },
      extmarks = {
        [1] = {
          { line_hl_group = 'OpencodeReasoningText' },
        },
      },
      actions = {},
    }, {
      lines = { 'alpha', 'beta' },
      extmarks = {},
      actions = {},
    })

    assert.stub(clear_extmarks_stub).was_called_with(11, 12)
    assert.stub(set_extmarks_stub).was_called_with({
      [0] = {
        { line_hl_group = 'OpencodeReasoningText' },
      },
    }, 11)
    assert_called_before(call_order, 'clear_extmarks', 'set_lines')
  end)

  it('reapplies extmarks at the correct line after unchanged leading lines', function()
    ctx.render_state:set_part({ id = 'part_1', messageID = 'msg_1', type = 'text' }, 20, 24)

    buffer.upsert_part_now('part_1', 'msg_1', {
      lines = { 'title', '', 'question', '    1. One', '    2. Two ' },
      extmarks = {
        [4] = {
          { line_hl_group = 'OpencodeDialogOptionHover' },
        },
      },
      actions = {},
    }, {
      lines = { 'title', '', 'question', '    1. One', '    2. Two' },
      extmarks = {
        [4] = {
          { line_hl_group = 'OpencodeDialogOptionHover' },
        },
      },
      actions = {},
    })

    assert.stub(clear_extmarks_stub).was_called_with(24, 25)
    assert.stub(set_extmarks_stub).was_called_with({
      [0] = {
        { line_hl_group = 'OpencodeDialogOptionHover' },
      },
    }, 24)
    assert_called_before(call_order, 'clear_extmarks', 'set_lines')
  end)

  it('clears extmarks before rewriting a message', function()
    ctx.render_state:set_message({ info = { id = 'msg_1' } }, 30, 31)

    buffer.upsert_message_now('msg_1', {
      lines = { 'alpha', '' },
      extmarks = {},
      actions = {},
    }, {
      lines = { 'alpha', 'beta' },
      extmarks = {
        [1] = {
          { virt_text = { { 'OLD', 'Normal' } }, virt_text_pos = 'overlay' },
        },
      },
      actions = {},
    })

    assert.stub(clear_extmarks_stub).was_called()
    assert_called_before(call_order, 'clear_extmarks', 'set_lines')
  end)
end)
