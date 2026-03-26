local buffer = require('opencode.ui.renderer.buffer')
local ctx = require('opencode.ui.renderer.ctx')
local output_window = require('opencode.ui.output_window')
local stub = require('luassert.stub')

describe('renderer.buffer extmarks', function()
  local set_lines_stub
  local clear_extmarks_stub
  local set_extmarks_stub
  local highlight_changed_lines_stub

  before_each(function()
    ctx:reset()
    set_lines_stub = stub(output_window, 'set_lines')
    clear_extmarks_stub = stub(output_window, 'clear_extmarks')
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
  end)
end)
