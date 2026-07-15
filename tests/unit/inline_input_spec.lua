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
      vim.api.nvim_win_close(anchor_win, true)
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

  local function change_text(input, text)
    vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { text })
    vim.api.nvim_exec_autocmds('TextChangedI', { buffer = input.buf, modeline = false })
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

  it('keeps its opening width while wrapped text grows and shrinks', function()
    local input = open_input(0, 0)
    local opening_width = vim.api.nvim_win_get_config(input.win).width

    assert.equals(50, opening_width)
    assert.equals(1, vim.api.nvim_win_get_config(input.win).height)

    change_text(input, string.rep('a', opening_width + 1))

    assert.equals(opening_width, vim.api.nvim_win_get_config(input.win).width)
    assert.equals(2, vim.api.nvim_win_get_config(input.win).height)

    change_text(input, 'short')

    assert.equals(opening_width, vim.api.nvim_win_get_config(input.win).width)
    assert.equals(1, vim.api.nvim_win_get_config(input.win).height)
    input.close()
  end)

  it('shrinks its opening width before the right border reaches the editor edge', function()
    local col = vim.api.nvim_win_get_width(anchor_win) - 2
    local input = open_input(0, col)
    local anchor = vim.fn.screenpos(anchor_win, 1, col + 1)
    local width = vim.api.nvim_win_get_config(input.win).width

    assert.equals(math.min(50, vim.o.columns - anchor.col - 1), width)
    assert.is_true(anchor.col + width + 1 <= vim.o.columns)
    input.close()
  end)

  it('caps its height below the screen edge while preserving wrapped text', function()
    local row = math.min(7, vim.o.lines - 4)
    local input = open_input(row, 0)
    local anchor = vim.fn.screenpos(anchor_win, row + 1, 1)
    local max_height = math.max(1, vim.o.lines - anchor.row - 2)

    change_text(input, string.rep('a', 50 * (max_height + 1)))

    assert.equals(max_height, vim.api.nvim_win_get_config(input.win).height)
    assert.is_true(vim.api.nvim_win_text_height(input.win, { start_row = 0, end_row = 0 }).all > max_height)
    input.close()
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
