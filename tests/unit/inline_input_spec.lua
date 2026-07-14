local inline_input = require('opencode.ui.inline_input')

describe('inline_input', function()
  local anchor_buf
  local anchor_win

  before_each(function()
    anchor_buf = vim.api.nvim_create_buf(false, true)
    anchor_win = vim.api.nvim_open_win(anchor_buf, true, {
      relative = 'editor',
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
  end)

  after_each(function()
    pcall(vim.api.nvim_win_close, anchor_win, true)
    pcall(vim.api.nvim_buf_delete, anchor_buf, { force = true })
  end)

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
    vim.wait(50, function()
      return vim.api.nvim_get_current_win() == first.win
    end)
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
    vim.wait(50, function()
      return vim.api.nvim_get_current_win() == second.win
    end)

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
    vim.wait(50, function()
      return vim.api.nvim_get_current_win() == input.win
    end)

    assert.are.same({ 'restored draft' }, vim.api.nvim_buf_get_lines(input.buf, 0, 1, false))

    vim.api.nvim_set_current_win(anchor_win)
    assert.are.equal(1, cancelled)
  end)
end)
