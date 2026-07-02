local buffer = require('opencode.ui.renderer.buffer')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')
local state = require('opencode.state')
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
    state.renderer.set_messages({})
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

  it('inserts regular messages above pinned bottom displays', function()
    local get_line_count_stub = stub(output_window, 'get_buf_line_count').returns(14)
    local shift_folds_stub = stub(output_window, 'shift_folds')
    state.renderer.set_messages({
      { info = { id = 'msg_1' } },
    })
    ctx.render_state:set_message({ info = { id = 'question-display-message' } }, 10, 12)
    ctx.render_state:set_message({ info = { id = 'msg_1' } })

    buffer.upsert_message_now('msg_1', {
      lines = { 'regular message' },
      extmarks = {},
      actions = {},
      fold_ranges = {},
    })

    assert.stub(set_lines_stub).was_called_with({ 'regular message' }, 10, 10)

    get_line_count_stub:revert()
    shift_folds_stub:revert()
    state.renderer.set_messages({})
  end)

  it('only clears and reapplies appended extmarks during append-only updates', function()
    ctx.render_state:set_part({ id = 'part_1', messageID = 'msg_1', type = 'text' }, 10, 11)
    ctx.formatted_parts['part_1'] = {
      lines = { 'alpha', 'beta', 'gamma' },
      extmarks = {
        [0] = {
          { line_hl_group = 'ExistingHighlight' },
        },
        [2] = {
          { line_hl_group = 'AppendedHighlight' },
        },
      },
      actions = {},
    }

    buffer.append_part_now('part_1', { 'gamma' }, nil, {
      lines = { 'alpha', 'beta' },
      extmarks = {
        [0] = {
          { line_hl_group = 'ExistingHighlight' },
        },
      },
      actions = {},
    })

    assert.stub(clear_extmarks_stub).was_called_with(12, 13)
    assert.stub(set_extmarks_stub).was_called_with({
      [0] = {
        { line_hl_group = 'AppendedHighlight' },
      },
    }, 12)
  end)

  it('replaces rendered targets with line offset when updating a part', function()
    ctx.render_state:set_part({ id = 'part_1', messageID = 'msg_1', type = 'text' }, 10, 10)
    ctx.render_state:add_targets('part_1', {
      {
        kind = 'file',
        path = 'old.lua',
        range = { line = 11, start_col = 0, end_col = 7 },
      },
    })

    buffer.upsert_part_now('part_1', 'msg_1', {
      lines = { 'new.lua' },
      extmarks = {},
      actions = {},
      targets = {
        {
          kind = 'file',
          path = 'new.lua',
          range = { line = 1, start_col = 0, end_col = 7 },
        },
      },
    }, {
      lines = { 'old.lua' },
      extmarks = {},
      actions = {},
      targets = {},
    })

    assert.is_nil(ctx.render_state:get_target_at_position(11, 1, function(target)
      return target.path == 'old.lua'
    end))

    local result = ctx.render_state:get_target_at_position(11, 1)
    assert.is_not_nil(result)
    assert.equals('new.lua', result.path)
  end)
end)

describe('update_part_folds', function()
  local set_folds_stub

  before_each(function()
    ctx:reset()
    set_folds_stub = stub(output_window, 'set_folds')
    ctx.global_folds = {}
    ctx.part_folds = {}
  end)

  after_each(function()
    set_folds_stub:revert()
    ctx:reset()
  end)

  it('computes absolute fold ranges for a single part', function()
    ctx.formatted_parts['part_a'] = {
      lines = { 'title', '', 'content', 'more' },
      fold_ranges = { { from = 1, to = 4 } },
    }
    ctx.render_state:set_part({ id = 'part_a', messageID = 'msg_1', type = 'text' }, 10, 14)

    buffer.update_part_folds('part_a')

    assert.stub(set_folds_stub).was_called_with({
      { from = 10, to = 13 },
    })
  end)

  it('skips set_folds when fold ranges have not changed', function()
    ctx.formatted_parts['part_a'] = {
      lines = { 'title', '', 'content', 'more' },
      fold_ranges = { { from = 1, to = 4 } },
    }
    ctx.render_state:set_part({ id = 'part_a', messageID = 'msg_1', type = 'text' }, 10, 14)

    buffer.update_part_folds('part_a')
    set_folds_stub:clear()

    buffer.update_part_folds('part_a')

    assert.stub(set_folds_stub).was_not_called()
  end)

  it('merges existing folds from other parts', function()
    ctx.part_folds['part_b'] = { { from = 5, to = 8 } }
    ctx.global_folds = { { from = 5, to = 8 } }

    ctx.formatted_parts['part_a'] = {
      lines = { 'title', '', 'content', 'more' },
      fold_ranges = { { from = 1, to = 4 } },
    }
    ctx.render_state:set_part({ id = 'part_a', messageID = 'msg_1', type = 'text' }, 10, 14)

    buffer.update_part_folds('part_a')

    assert.stub(set_folds_stub).was_called_with({
      { from = 5, to = 8 },
      { from = 10, to = 13 },
    })
  end)
end)
