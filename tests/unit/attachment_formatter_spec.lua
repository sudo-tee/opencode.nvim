local assert = require('luassert')
local stub = require('luassert.stub')
local contexts = require('opencode.ui.renderer.ctx')
local formatter = require('opencode.ui.formatter')
local opencode = require('opencode')
local registry = require('opencode.ui.formatter.attachment_registry')
local state = require('opencode.state')

describe('attachment formatters', function()
  local function image_part(uri)
    return { kind = 'file', name = 'pasted_image_1.png', media_type = 'image/png', uri = uri }
  end

  local function render(part, part_id)
    local message = { id = 'msg_attachment', kind = 'user', content = { part } }
    return formatter.format_part(part, message, true, nil, part_id)
  end

  after_each(function()
    registry._reset()
  end)

  it('lets the first formatter that writes lines render a file attachment', function()
    local seen
    opencode.register_attachment_formatter('declines', {
      format = function() end,
    })
    opencode.register_attachment_formatter('image', {
      format = function(output, attachment)
        seen = attachment
        output:add_line('image ' .. attachment.name)
        output:add_line('')
      end,
    })

    local output = render(image_part('file:///tmp/pasted_image_1.png'), 'msg_attachment:content:1')

    assert.same({ 'image pasted_image_1.png', '' }, output.lines)
    assert.same({
      name = 'pasted_image_1.png',
      uri = 'file:///tmp/pasted_image_1.png',
      media_type = 'image/png',
      path = '/tmp/pasted_image_1.png',
      part_id = 'msg_attachment:content:1',
    }, seen)
    assert.is_not_nil(output.extmarks[0][1].virt_text)
  end)

  it('falls back to the default file line when every formatter declines', function()
    opencode.register_attachment_formatter('declines', {
      format = function() end,
    })

    local output = render(image_part('data:image/png;base64,AAAA'))

    assert.same({ '[`pasted_image_1.png`](pasted_image_1.png)', '' }, output.lines)
  end)

  it('discards partial output from a failing formatter and logs the error once', function()
    local original_log = package.loaded['opencode.log']
    local errors = {}
    package.loaded['opencode.log'] = {
      error = function(message)
        errors[#errors + 1] = message
      end,
    }
    opencode.register_attachment_formatter('broken', {
      format = function(output)
        output:add_line('partial')
        error('boom')
      end,
    })

    local first = render(image_part('data:image/png;base64,AAAA'))
    render(image_part('data:image/png;base64,AAAA'))
    package.loaded['opencode.log'] = original_log

    assert.same({ '[`pasted_image_1.png`](pasted_image_1.png)', '' }, first.lines)
    assert.equals(1, #errors)
    assert.matches('Attachment formatter "broken" failed: .*boom', errors[1])
  end)

  it('rejects duplicate names and unregisters by name', function()
    opencode.register_attachment_formatter('image', { format = function() end })

    assert.has_error(function()
      opencode.register_attachment_formatter('image', { format = function() end })
    end, 'Attachment formatter already registered: image')
    assert.is_true(opencode.unregister_attachment_formatter('image'))
    assert.is_false(opencode.unregister_attachment_formatter('image'))
  end)
end)

describe('get_rendered_part', function()
  local original_windows

  before_each(function()
    contexts.current():reset()
    original_windows = state.windows
  end)

  after_each(function()
    state.ui.set_windows(original_windows)
    contexts.current():reset()
  end)

  it('returns 1-indexed buffer lines and the window showing the output', function()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_get_current_win()
    local previous = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buf)
    state.ui.set_windows({ output_buf = buf, output_win = win })
    contexts.current().render_state:set_part({ kind = 'file' }, 'msg1', 'msg1:content:2', 5, 9)

    local lines = opencode.get_rendered_part('msg1:content:2')
    vim.api.nvim_win_set_buf(win, previous)
    local hidden = opencode.get_rendered_part('msg1:content:2')
    vim.api.nvim_buf_delete(buf, { force = true })

    assert.same({ buf = buf, win = win, first = 6, last = 10 }, lines)
    assert.same({ buf = buf, first = 6, last = 10 }, hidden)
    assert.is_nil(opencode.get_rendered_part('missing'))
  end)
end)

describe('OpencodeOutputRendered', function()
  it('fires after a bulk render writes the output buffer', function()
    local flush = require('opencode.ui.renderer.flush')
    local output_window = require('opencode.ui.output_window')
    local original_windows = state.windows
    local buf = vim.api.nvim_create_buf(false, true)
    state.ui.set_windows({ output_buf = buf })
    local stubs = { stub(output_window, 'set_folds'), stub(output_window, 'clear_extmarks') }
    local fired
    local id = vim.api.nvim_create_autocmd('User', {
      pattern = 'OpencodeOutputRendered',
      callback = function(args)
        fired = args.data
      end,
    })

    flush.begin_bulk_mode()
    contexts.current().bulk_buffer_lines = { 'hello' }
    flush.end_bulk_mode()

    vim.api.nvim_del_autocmd(id)
    for _, s in ipairs(stubs) do
      s:revert()
    end
    state.ui.set_windows(original_windows)
    vim.api.nvim_buf_delete(buf, { force = true })
    contexts.current():reset()

    assert.same({ buf = buf }, fired)
  end)
end)
