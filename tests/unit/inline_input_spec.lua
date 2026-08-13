local inline_input = require('opencode.ui.inline_input')
local stub = require('luassert.stub')

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

  describe('history navigation (<C-p> / <C-n>)', function()
    local histget_stub
    local histadd_stub

    -- Build a vim.fn.histget stub that mirrors vim's "input" history: negative
    -- indices walk from most recent backwards, and any further-out entry
    -- returns '' (matching the real |histget()|).
    local function with_history(history)
      histget_stub:revert()
      histget_stub = stub(vim.fn, 'histget')
      histget_stub.invokes(function(history_name, idx)
        assert.equals('input', history_name)
        local real = idx
        if type(real) == 'number' and real < 0 then
          local entry = history[-real]
          return entry or ''
        end
        return ''
      end)

      histadd_stub:revert()
      histadd_stub = stub(vim.fn, 'histadd')
      histadd_stub.returns(1)
    end

    -- Invoke the buffer-local insert-mode keymap callback directly. This
    -- avoids headless mode quirks where nvim_buf_set_lines can drop us out
    -- of insert mode, and lets us assert the keymap wiring + history state
    -- machine independently of the mode state.
    local function call_keymap(input, lhs)
      local target = lhs:gsub('^<(.-)>$', function(k)
        return '<' .. k:upper() .. '>'
      end)
      for _, m in ipairs(vim.api.nvim_buf_get_keymap(input.buf, 'i')) do
        if m.lhs == target and m.callback then
          m.callback()
          return true
        end
      end
      return false
    end

    local function buf_lines(input)
      return vim.api.nvim_buf_get_lines(input.buf, 0, -1, false)
    end

    before_each(function()
      histget_stub = stub(vim.fn, 'histget')
      histadd_stub = stub(vim.fn, 'histadd')
    end)

    after_each(function()
      if histget_stub then
        histget_stub:revert()
      end
      if histadd_stub then
        histadd_stub:revert()
      end
    end)

    it('walks forward through history with <C-p>', function()
      with_history({ [1] = 'newest', [2] = 'middle', [3] = 'oldest' })
      local input = open_input(0, 0)

      assert.is_true(call_keymap(input, '<C-p>'))
      assert.are.same({ 'newest' }, buf_lines(input))

      assert.is_true(call_keymap(input, '<C-p>'))
      assert.are.same({ 'middle' }, buf_lines(input))

      assert.is_true(call_keymap(input, '<C-p>'))
      assert.are.same({ 'oldest' }, buf_lines(input))
    end)

    it('caps <C-p> at the oldest history entry', function()
      with_history({ [1] = 'newest', [2] = 'middle' })
      local input = open_input(0, 0)

      for _ = 1, 5 do
        call_keymap(input, '<C-p>')
      end
      assert.are.same({ 'middle' }, buf_lines(input))
    end)

    it('restores the in-progress draft with <C-n>', function()
      with_history({ [1] = 'newest', [2] = 'middle' })
      local input = open_input(0, 0)

      vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { 'draft' })
      call_keymap(input, '<C-p>')
      assert.are.same({ 'newest' }, buf_lines(input))

      call_keymap(input, '<C-n>')
      assert.are.same({ 'draft' }, buf_lines(input))
    end)

    it('walks back through history with <C-n>', function()
      with_history({ [1] = 'newest', [2] = 'middle', [3] = 'oldest' })
      local input = open_input(0, 0)

      call_keymap(input, '<C-p>')
      call_keymap(input, '<C-p>')
      call_keymap(input, '<C-p>')
      assert.are.same({ 'oldest' }, buf_lines(input))

      call_keymap(input, '<C-n>')
      assert.are.same({ 'middle' }, buf_lines(input))

      call_keymap(input, '<C-n>')
      assert.are.same({ 'newest' }, buf_lines(input))
    end)

    it('is a no-op when <C-p> is pressed with empty history', function()
      with_history({})
      local input = open_input(0, 0)

      vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { 'draft' })
      call_keymap(input, '<C-p>')
      assert.are.same({ 'draft' }, buf_lines(input))
    end)

    it('is a no-op when <C-n> is pressed without first entering history', function()
      with_history({ [1] = 'newest' })
      local input = open_input(0, 0)

      vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { 'draft' })
      call_keymap(input, '<C-n>')
      assert.are.same({ 'draft' }, buf_lines(input))
    end)

    it('handles multi-line history entries', function()
      with_history({ [1] = 'line1\nline2' })
      local input = open_input(0, 0)

      call_keymap(input, '<C-p>')
      assert.are.same({ 'line1', 'line2' }, buf_lines(input))
    end)

    it('places the cursor at the end of the inserted history entry', function()
      with_history({ [1] = 'first', [2] = 'second' })
      local input = open_input(0, 0)

      call_keymap(input, '<C-p>')
      local cursor1 = vim.api.nvim_win_get_cursor(input.win)
      -- Cursor lands on the last char (normal-mode clamp) or the append
      -- position (insert-mode). Production runs in insert mode, so this
      -- matches user-visible behavior either way.
      assert.are.equal(1, cursor1[1])
      assert.is_true(cursor1[2] == #('first') or cursor1[2] == #('first') - 1)

      call_keymap(input, '<C-p>')
      local cursor2 = vim.api.nvim_win_get_cursor(input.win)
      assert.are.equal(1, cursor2[1])
      assert.is_true(cursor2[2] == #('second') or cursor2[2] == #('second') - 1)
    end)

    it('after restoring the draft, <C-p> re-enters history from the snapshot', function()
      with_history({ [1] = 'alpha', [2] = 'beta' })
      local input = open_input(0, 0)

      vim.api.nvim_buf_set_lines(input.buf, 0, 1, false, { 'typed' })
      call_keymap(input, '<C-p>')
      call_keymap(input, '<C-n>')
      assert.are.same({ 'typed' }, buf_lines(input))

      call_keymap(input, '<C-p>')
      assert.are.same({ 'alpha' }, buf_lines(input))
    end)

    it('writes submitted text to vim\'s "input" history (shared with vim.fn.input)', function()
      with_history({})

      local submitted
      open_input(0, 0, function(value)
        submitted = value
      end)
      vim.api.nvim_feedkeys(vim.keycode('ianswer<CR>'), 'x', false)

      assert.equals('answer', submitted)
      assert.stub(histadd_stub).was_called_with('input', 'answer')
    end)

    it('does not write to history when submission is empty', function()
      with_history({})

      local submitted
      open_input(0, 0, function(value)
        submitted = value
      end)
      vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)

      assert.is_nil(submitted)
      assert.stub(histadd_stub).was_not_called()
    end)
  end)
end)
