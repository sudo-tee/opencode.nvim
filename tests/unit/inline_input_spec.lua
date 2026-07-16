local inline_input = require('opencode.ui.inline_input')

describe('inline_input', function()
  local anchor_buf
  local anchor_win

  before_each(function()
    local lines = {}
    for i = 1, 10 do
      lines[i] = string.rep('a', vim.o.columns)
    end

    anchor_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(anchor_buf, 0, -1, false, lines)
    anchor_win = vim.api.nvim_open_win(anchor_buf, true, {
      relative = 'editor',
      row = 0,
      col = 0,
      width = vim.o.columns - 1,
      height = 10,
    })
  end)

  after_each(function()
    if vim.api.nvim_win_is_valid(anchor_win) then
      pcall(vim.api.nvim_win_close, anchor_win, true)
    end
    if vim.api.nvim_buf_is_valid(anchor_buf) then
      vim.api.nvim_buf_delete(anchor_buf, { force = true })
    end
  end)

  local function open_input(row, col, on_submit)
    local input = inline_input.open({
      win = anchor_win,
      row = row,
      col = col,
      title = 'Answer',
      on_submit = on_submit or function() end,
      on_cancel = function() end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
    end))
    return input
  end

  local function use_regular_anchor()
    vim.api.nvim_win_close(anchor_win, true)
    anchor_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(anchor_win, anchor_buf)
    vim.wo[anchor_win].wrap = false
    vim.wo[anchor_win].signcolumn = 'no'
    vim.wo[anchor_win].foldcolumn = '0'
    vim.wo[anchor_win].number = false
    vim.wo[anchor_win].relativenumber = false
  end

  local function change_text(input, text, expected_height)
    vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { text })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = input.buf, modeline = false })
    assert.is_true(vim.wait(100, function()
      return vim.api.nvim_win_get_config(input.win).height == expected_height
    end))
  end

  it('is stateless across opens (no implicit carry-over)', function()
    local first_cancelled = 0
    local second_cancelled = 0
    local submitted = 0

    local first = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      title = 'First',
      on_submit = function()
        submitted = submitted + 1
      end,
      on_cancel = function()
        first_cancelled = first_cancelled + 1
      end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == first.win
    end))
    vim.api.nvim_buf_set_lines(first.buf, 0, 1, false, { 'draft from first input' })
    vim.api.nvim_set_current_win(anchor_win)

    assert.are.equal(1, first_cancelled)

    local second = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      title = 'Second',
      on_submit = function()
        submitted = submitted + 1
      end,
      on_cancel = function()
        second_cancelled = second_cancelled + 1
      end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == second.win
    end))

    assert.are.same({ '' }, vim.api.nvim_buf_get_lines(second.buf, 0, 1, false))

    vim.api.nvim_set_current_win(anchor_win)
    assert.are.equal(1, second_cancelled)
    assert.are.equal(0, submitted)
  end)

  it('restores initial_text when provided', function()
    local cancelled = 0

    local input = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      initial_text = 'restored draft',
      on_submit = function() end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
    end))

    assert.are.same({ 'restored draft' }, vim.api.nvim_buf_get_lines(input.buf, 0, 1, false))

    vim.api.nvim_set_current_win(anchor_win)
    assert.are.equal(1, cancelled)
  end)

  it('restores multiline initial_text and places the cursor at its end', function()
    local input = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      initial_text = 'first line\nsecond line',
      on_submit = function() end,
      on_cancel = function() end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
        and vim.deep_equal(vim.api.nvim_win_get_cursor(input.win), { 2, #'second line' })
    end))

    assert.are.same({ 'first line', 'second line' }, vim.api.nvim_buf_get_lines(input.buf, 0, -1, false))
    input.close()
  end)

  it('keeps its opening width while wrapped text grows and shrinks', function()
    local input = open_input(0, 0)
    local opening_width = vim.api.nvim_win_get_config(input.win).width

    assert.equals(50, opening_width)
    assert.equals(1, vim.api.nvim_win_get_config(input.win).height)

    change_text(input, string.rep('a', opening_width + 1), 2)

    assert.equals(opening_width, vim.api.nvim_win_get_config(input.win).width)
    assert.equals(2, vim.api.nvim_win_get_config(input.win).height)

    change_text(input, 'short', 1)

    assert.equals(opening_width, vim.api.nvim_win_get_config(input.win).width)
    assert.equals(1, vim.api.nvim_win_get_config(input.win).height)
    input.close()
  end)

  it('shrinks its opening width before the right border reaches the editor edge', function()
    use_regular_anchor()
    local col = vim.api.nvim_win_get_width(anchor_win) - 2
    local input = open_input(0, col)
    local anchor = vim.fn.screenpos(anchor_win, 1, col + 1)
    local width = vim.api.nvim_win_get_config(input.win).width
    local position = vim.api.nvim_win_get_position(input.win)

    assert.equals(math.max(1, math.min(50, vim.o.columns - anchor.col - 1)), width)
    assert.is_true(position[2] + width + 2 <= vim.o.columns)
    input.close()
  end)

  it('caps its height below the screen edge while preserving wrapped text', function()
    local row = math.min(7, vim.o.lines - 4)
    local input = open_input(row, 0)
    local anchor = vim.fn.screenpos(anchor_win, row + 1, 1)
    local max_height = math.max(1, vim.o.lines - anchor.row - 2)

    change_text(input, string.rep('a', 50 * (max_height + 1)), max_height)

    assert.equals(max_height, vim.api.nvim_win_get_config(input.win).height)
    assert.is_true(vim.api.nvim_win_text_height(input.win, { start_row = 0, end_row = 0 }).all > max_height)
    input.close()
  end)

  it('keeps its rounded border inside the editor at the bottom-right edge', function()
    vim.api.nvim_win_close(anchor_win, true)
    vim.cmd('botright 10vnew')
    vim.cmd('botright 1new')
    anchor_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(anchor_win, anchor_buf)
    vim.wo[anchor_win].wrap = false
    vim.wo[anchor_win].signcolumn = 'no'
    vim.wo[anchor_win].foldcolumn = '0'

    local col = vim.api.nvim_win_get_width(anchor_win) - 3
    local anchor = vim.fn.screenpos(anchor_win, 1, col + 1)
    assert.equals(vim.o.lines - 2, anchor.row)

    local input = open_input(0, col)
    local position = vim.api.nvim_win_get_position(input.win)
    local window_config = vim.api.nvim_win_get_config(input.win)

    assert.is_true(
      position[2] + window_config.width + 2 <= vim.o.columns,
      vim.inspect({ position = position, config = window_config, columns = vim.o.columns, lines = vim.o.lines })
    )
    assert.is_true(
      position[1] + window_config.height + 2 <= vim.o.lines,
      vim.inspect({ position = position, config = window_config, columns = vim.o.columns, lines = vim.o.lines })
    )
    input.close()
    vim.cmd('only')
  end)

  it('removes its WinClosed watcher after closing', function()
    local before = #vim.api.nvim_get_autocmds({ event = 'WinClosed' })

    for _ = 1, 5 do
      local input = open_input(0, 0)
      input.close()
    end

    assert.equals(before, #vim.api.nvim_get_autocmds({ event = 'WinClosed' }))
  end)

  it('resizes after multiline text changes outside insert mode', function()
    local input = open_input(0, 0)
    local lines = {
      'local function one()',
      '  print("one")',
      'end',
      'return one',
    }

    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, lines)
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = input.buf, modeline = false })

    assert.is_true(vim.wait(100, function()
      return vim.api.nvim_win_get_config(input.win).height == #lines
    end))
    input.close()
  end)

  it('returns the full draft when cancelled with Ctrl-C', function()
    local draft
    local cancelled = 0
    local input = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      on_submit = function() end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
      on_leave = function(text)
        draft = text
      end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
    end))

    local lines = { 'local value = 1', 'return value' }
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, lines)
    vim.api.nvim_feedkeys(vim.keycode('i<C-c>'), 'x', false)

    assert.equals(table.concat(lines, '\n'), draft)
    assert.equals(1, cancelled)
  end)

  it('returns the draft and closes when its anchor window closes', function()
    local draft
    local cancelled = 0
    local input = inline_input.open({
      win = anchor_win,
      row = 0,
      col = 0,
      on_submit = function() end,
      on_cancel = function()
        cancelled = cancelled + 1
      end,
      on_leave = function(text)
        draft = text
      end,
    })
    assert.is_true(vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
    end))

    local lines = { 'first line', 'second line' }
    vim.api.nvim_buf_set_lines(input.buf, 0, -1, false, lines)
    vim.api.nvim_win_close(anchor_win, true)

    assert.is_false(vim.api.nvim_win_is_valid(input.win))
    assert.equals(table.concat(lines, '\n'), draft)
    assert.equals(1, cancelled)
  end)

  it('submits every character from a wrapped mixed-language line', function()
    local submitted
    local text = 'English 中文 mixed ' .. string.rep('长文本', 40)

    open_input(0, 0, function(value)
      submitted = value
    end)
    vim.api.nvim_feedkeys(vim.keycode('i' .. text .. '<CR>'), 'x', false)

    assert.equals(text, submitted)
  end)
end)
