local config = require('opencode.config')
local state = require('opencode.state')
local formatter = require('opencode.ui.formatter')
local output_window = require('opencode.ui.output_window')
local contexts = require('opencode.ui.renderer.ctx')
local buffer = require('opencode.ui.renderer.buffer')
local stub = require('luassert.stub')
local Output = require('opencode.ui.output')

describe('folded streaming previews', function()
  local original_config
  local buf, win, ctx, previous
  local message = { id = 'msg', kind = 'assistant' }

  local function render(part)
    local formatted = formatter.format_part(part, message, true)
    ctx.formatted_parts.part = formatted
    if previous then
      buffer.upsert_part_now('part', 'msg', formatted, previous, ctx)
    else
      output_window.set_lines(formatted.lines)
      ctx.render_state:set_part(part, 'msg', 'part', 0, #formatted.lines - 1)
      buffer.set_all_folds(ctx)
    end
    previous = formatted
    return formatted
  end

  local function closed_at(text)
    for line, value in ipairs(previous.lines) do
      if value == text then
        return vim.api.nvim_win_call(win, function()
          return vim.fn.foldclosed(line)
        end)
      end
    end
    error('Missing rendered line: ' .. text)
  end

  local function reasoning(text, time)
    return { id = 'part', kind = 'reasoning', text = text, time = time or { started = 1 } }
  end

  before_each(function()
    original_config = vim.deepcopy(config.values)
    config.setup({ ui = { output = { tools = { show_output = false, show_reasoning_output = false } } } })
    ctx = contexts.new()
    previous = nil
    buf = vim.api.nvim_create_buf(false, true)
    win = vim.api.nvim_open_win(buf, true, { relative = 'editor', width = 80, height = 10, row = 0, col = 0 })
    state.ui.set_windows({ output_buf = buf, output_win = win })
    output_window.setup({ output_buf = buf, output_win = win })
  end)

  after_each(function()
    state.ui.set_windows(nil)
    vim.api.nvim_win_close(win, true)
    vim.api.nvim_buf_delete(buf, { force = true })
    config.values = original_config
  end)

  it('keeps reasoning title and latest content visible through rewrites and completion', function()
    render(reasoning('first\nsecond\nlast'))
    assert.is_true(closed_at('first') > 0)
    assert.equals(-1, closed_at('last'))
    assert.equals(
      -1,
      vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(1)
      end)
    )

    render(reasoning('first\nsecond\nlast token'))
    assert.equals(-1, closed_at('last token'))
    render(reasoning('first\nsecond\nlast token\nnew tail'))
    assert.is_true(closed_at('last token') > 0)
    assert.equals(-1, closed_at('new tail'))

    render(reasoning('first\nsecond\nlast token\nnew tail', { started = 1, completed = 2 }))
    assert.is_true(closed_at('new tail') > 0)
    assert.equals(
      -1,
      vim.api.nvim_win_call(win, function()
        return vim.fn.foldclosed(1)
      end)
    )
  end)

  it('supports V2 reasoning timestamps and multiple preview lines', function()
    config.values.ui.output.tools.streaming_preview_lines = 2
    render(reasoning('first\nsecond\nthird\nlast', { created = 1 }))
    assert.is_true(closed_at('second') > 0)
    assert.equals(-1, closed_at('third'))
    assert.equals(-1, closed_at('last'))
  end)

  it('disables the preview with zero', function()
    config.values.ui.output.tools.streaming_preview_lines = 0
    render(reasoning('first\nsecond\nlast'))
    assert.is_true(closed_at('last') > 0)
  end)

  it('does not preview completed reasoning with missing timing metadata', function()
    render({ id = 'part', kind = 'reasoning', text = 'first\nsecond\nlast' })
    assert.is_true(closed_at('last') > 0)
  end)

  it('preserves user-opened reasoning folds while streaming and on completion', function()
    render(reasoning('first\nsecond\nlast'))
    vim.api.nvim_win_call(win, function()
      vim.cmd(previous.fold_ranges[1].from .. 'foldopen!')
    end)
    render(reasoning('first\nsecond\nlast\nnew tail'))
    assert.equals(-1, closed_at('first'))
    render(reasoning('first\nsecond\nlast\nnew tail', { started = 1, completed = 2 }))
    assert.equals(-1, closed_at('first'))
  end)

  it('previews tool content rather than its closing code fence', function()
    local part = {
      id = 'part',
      kind = 'tool',
      name = 'bash',
      state = 'running',
      input = { command = 'build' },
      result = { { kind = 'text', text = 'first\nsecond\nlast' } },
    }
    render(part)
    assert.is_true(closed_at('first') > 0)
    assert.equals(-1, closed_at('last'))
    part.state = 'completed'
    render(part)
    assert.is_true(closed_at('last') > 0)
  end)

  it('does not rebuild history folds for token-by-token preview changes', function()
    render(reasoning('first\nsecond\nlast'))
    local set_folds = stub(output_window, 'set_folds')
    for i = 1, 100 do
      render(reasoning('first\nsecond\nlast ' .. i))
    end
    assert.stub(set_folds).was_not_called()
    set_folds:revert()
    assert.is_true(closed_at('first') > 0)
    assert.equals(-1, closed_at('last 100'))
  end)

  it('respects disabled folds', function()
    config.values.ui.output.tools.use_folds = false
    config.values.ui.output.tools.show_reasoning_output = true
    render(reasoning('first\nsecond\nlast'))
    assert.same({}, previous.fold_ranges)
    assert.equals(-1, closed_at('first'))
  end)

  it('advances the preview during append-only buffer updates', function()
    local initial = Output.new()
    initial:add_lines({ 'title', 'first', 'second', 'last' })
    initial:add_fold(2, 4)
    initial:preview_fold_tail(1)
    output_window.set_lines(initial.lines)
    ctx.render_state:set_part({ id = 'part', kind = 'reasoning' }, 'msg', 'part', 0, 3)
    ctx.formatted_parts.part = initial
    buffer.set_all_folds(ctx)

    local appended = Output.new()
    appended:add_lines({ 'title', 'first', 'second', 'last', 'new tail' })
    appended:add_fold(2, 5)
    appended:preview_fold_tail(1)
    ctx.formatted_parts.part = appended
    buffer.append_part_now('part', { 'new tail' }, nil, initial, ctx)
    previous = appended
    assert.is_true(closed_at('last') > 0)
    assert.equals(-1, closed_at('new tail'))
  end)
end)
