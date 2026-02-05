local buf_fix_win = require('opencode.ui.buf_fix_win')

describe('buf_fix_win module', function()
  local test_bufs = {}
  local test_wins = {}

  local function create_test_buffer()
    local buf = vim.api.nvim_create_buf(false, true)
    table.insert(test_bufs, buf)
    return buf
  end

  local function create_test_window(buf)
    vim.cmd('split')
    local win = vim.api.nvim_get_current_win()
    if buf then
      vim.api.nvim_win_set_buf(win, buf)
    end
    table.insert(test_wins, win)
    return win
  end

  local function cleanup_test_windows()
    for _, win in ipairs(test_wins) do
      if vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end
    test_wins = {}
  end

  local function cleanup_test_buffers()
    for _, buf in ipairs(test_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    test_bufs = {}
  end

  after_each(function()
    cleanup_test_windows()
    cleanup_test_buffers()
    vim.cmd('only')
  end)

  describe('fix_to_win', function()
    it('should prevent buffer from appearing in multiple windows', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return win1
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      local win2 = create_test_window()
      vim.api.nvim_win_set_buf(win2, buf)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win2)
      end)

      assert.is_false(vim.api.nvim_win_is_valid(win2))
      assert.is_true(vim.api.nvim_win_is_valid(win1))
    end)

    it('should keep buffer in intended window', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return win1
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      assert.equal(vim.api.nvim_win_get_buf(win1), buf)
    end)

    it('should handle nil intended window gracefully', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return nil
      end

      assert.has_no.errors(function()
        buf_fix_win.fix_to_win(buf, get_intended_window)

        local other_window = create_test_window()
        vim.api.nvim_win_set_buf(other_window, buf)

        -- Give scheduled tasks time to run
        vim.wait(100, function()
          return false
        end)

        assert.is_true(vim.api.nvim_win_is_valid(win1))
        assert.is_true(vim.api.nvim_win_is_valid(other_window))
      end)
    end)

    it('should close duplicates when buffer appears in multiple windows', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)
      local win2 = create_test_window(buf)
      local win3 = create_test_window(buf)

      assert.equal(vim.api.nvim_win_get_buf(win1), buf)
      assert.equal(vim.api.nvim_win_get_buf(win2), buf)
      assert.equal(vim.api.nvim_win_get_buf(win3), buf)

      local get_intended_window = function()
        return win1
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win2) and not vim.api.nvim_win_is_valid(win3)
      end)

      -- Only win1 should remain
      assert.is_true(vim.api.nvim_win_is_valid(win1))

      assert.is_false(vim.api.nvim_win_is_valid(win2))
      assert.is_false(vim.api.nvim_win_is_valid(win3))
    end)

    it('should work when buffer has only one window', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return win1
      end

      assert.has_no.errors(function()
        buf_fix_win.fix_to_win(buf, get_intended_window)
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
      assert.equal(vim.api.nvim_win_get_buf(win1), buf)
    end)

    it('should handle dynamic intended window changes', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)
      local win2 = create_test_window()

      local intended_window = win1
      local get_intended_window = function()
        return intended_window
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      -- Change intended window
      intended_window = win2
      vim.api.nvim_win_set_buf(win2, buf)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win1)
      end)

      -- Win1 should be closed, win2 should remain
      assert.is_false(vim.api.nvim_win_is_valid(win1))
      assert.is_true(vim.api.nvim_win_is_valid(win2))
    end)

    it('should handle WinNew autocmd for new windows', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return win1
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      -- Create a new window and try to switch to the buffer
      vim.cmd('split')
      local new_win = vim.api.nvim_get_current_win()
      table.insert(test_wins, new_win)

      vim.api.nvim_win_set_buf(new_win, buf)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(new_win)
      end)

      -- New window should be closed
      assert.is_false(vim.api.nvim_win_is_valid(new_win))
      assert.is_true(vim.api.nvim_win_is_valid(win1))
    end)

    it('should not close intended window even if it is a duplicate', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)
      local win2 = create_test_window(buf)

      local get_intended_window = function()
        return win1
      end

      buf_fix_win.fix_to_win(buf, get_intended_window)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win2)
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
      assert.is_false(vim.api.nvim_win_is_valid(win2))
    end)

    it('should handle multiple buffers with different intended windows', function()
      local buf1 = create_test_buffer()
      local buf2 = create_test_buffer()

      local win1 = create_test_window(buf1)
      local win2 = create_test_window(buf2)

      buf_fix_win.fix_to_win(buf1, function()
        return win1
      end)
      buf_fix_win.fix_to_win(buf2, function()
        return win2
      end)

      -- Try to swap buffers
      local win3 = create_test_window()
      local win4 = create_test_window()

      vim.api.nvim_win_set_buf(win3, buf1)
      vim.api.nvim_win_set_buf(win4, buf2)

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win3) and not vim.api.nvim_win_is_valid(win4)
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
      assert.is_true(vim.api.nvim_win_is_valid(win2))
      assert.is_false(vim.api.nvim_win_is_valid(win3))
      assert.is_false(vim.api.nvim_win_is_valid(win4))
    end)

    it('should handle invalid window from get_intended_window', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      local get_intended_window = function()
        return 99999 -- Invalid window ID
      end

      assert.has_no.errors(function()
        buf_fix_win.fix_to_win(buf, get_intended_window)

        -- Try to open in another window
        local win2 = create_test_window()
        vim.api.nvim_win_set_buf(win2, buf)

        vim.wait(100, function()
          return false
        end)
      end)
    end)
  end)

  describe('autocmd setup behavior', function()
    local fresh_buf_fix_win

    before_each(function()
      -- Reload module to reset internal state for these tests only
      package.loaded['opencode.ui.buf_fix_win'] = nil
      fresh_buf_fix_win = require('opencode.ui.buf_fix_win')
    end)

    after_each(function()
      -- Restore the original module for other tests
      package.loaded['opencode.ui.buf_fix_win'] = nil
      buf_fix_win = require('opencode.ui.buf_fix_win')
    end)

    it('should setup global WinNew autocmd when fix_to_win is first called', function()
      local buf = create_test_buffer()
      local win = create_test_window(buf)

      local initial_autocmds = #vim.api.nvim_get_autocmds({ event = 'WinNew' })

      fresh_buf_fix_win.fix_to_win(buf, function()
        return win
      end)

      local final_autocmds = #vim.api.nvim_get_autocmds({ event = 'WinNew' })

      assert.equal(initial_autocmds + 1, final_autocmds)
    end)

    it('should not duplicate global WinNew autocmd on subsequent calls', function()
      local buf1 = create_test_buffer()
      local buf2 = create_test_buffer()
      local win1 = create_test_window(buf1)
      local win2 = create_test_window(buf2)

      fresh_buf_fix_win.fix_to_win(buf1, function()
        return win1
      end)

      local after_first_call = #vim.api.nvim_get_autocmds({ event = 'WinNew' })

      fresh_buf_fix_win.fix_to_win(buf2, function()
        return win2
      end)

      local after_second_call = #vim.api.nvim_get_autocmds({ event = 'WinNew' })

      assert.equal(after_first_call, after_second_call)
    end)

    it('should create BufWinEnter autocmd for each buffer', function()
      local buf = create_test_buffer()
      local win = create_test_window(buf)

      local initial_autocmds = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf })

      fresh_buf_fix_win.fix_to_win(buf, function()
        return win
      end)

      local final_autocmds = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf })

      assert.equal(initial_autocmds + 1, final_autocmds)
    end)

    it('should create separate BufWinEnter autocmds for different buffers', function()
      local buf1 = create_test_buffer()
      local buf2 = create_test_buffer()
      local win1 = create_test_window(buf1)
      local win2 = create_test_window(buf2)

      local initial_buf1 = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf1 })
      local initial_buf2 = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf2 })

      fresh_buf_fix_win.fix_to_win(buf1, function()
        return win1
      end)
      fresh_buf_fix_win.fix_to_win(buf2, function()
        return win2
      end)

      local final_buf1 = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf1 })
      local final_buf2 = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf2 })

      assert.equal(initial_buf1 + 1, final_buf1)
      assert.equal(initial_buf2 + 1, final_buf2)
    end)

    it('should not accumulate BufWinEnter autocmds when fix_to_win is called multiple times for same buffer', function()
      local buf = create_test_buffer()
      local win = create_test_window(buf)

      local initial = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf })

      fresh_buf_fix_win.fix_to_win(buf, function()
        return win
      end)
      local after_first = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf })
      fresh_buf_fix_win.fix_to_win(buf, function()
        return win
      end)
      local after_second = #vim.api.nvim_get_autocmds({ event = 'BufWinEnter', buffer = buf })

      assert.equal(initial + 1, after_first)
      assert.equal(initial + 1, after_second)
    end)

    it('should setup global VimResized autocmd when fix_to_win is first called', function()
      local buf = create_test_buffer()
      local win = create_test_window(buf)

      local initial_autocmds = #vim.api.nvim_get_autocmds({ event = 'VimResized' })

      fresh_buf_fix_win.fix_to_win(buf, function()
        return win
      end)

      local final_autocmds = #vim.api.nvim_get_autocmds({ event = 'VimResized' })

      assert.equal(initial_autocmds + 1, final_autocmds)
    end)

    it('should not duplicate global VimResized autocmd on subsequent calls', function()
      local buf1 = create_test_buffer()
      local buf2 = create_test_buffer()
      local win1 = create_test_window(buf1)
      local win2 = create_test_window(buf2)

      fresh_buf_fix_win.fix_to_win(buf1, function()
        return win1
      end)

      local after_first_call = #vim.api.nvim_get_autocmds({ event = 'VimResized' })

      fresh_buf_fix_win.fix_to_win(buf2, function()
        return win2
      end)

      local after_second_call = #vim.api.nvim_get_autocmds({ event = 'VimResized' })

      assert.equal(after_first_call, after_second_call)
    end)
  end)

  describe('VimResized event handling', function()
    it('should close duplicate windows on VimResized', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)
      local win2 = create_test_window(buf)

      buf_fix_win.fix_to_win(buf, function()
        return win1
      end)

      -- Simulate VimResized event
      vim.cmd('doautocmd VimResized')

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win2)
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
      assert.is_false(vim.api.nvim_win_is_valid(win2))
    end)

    it('should handle VimResized with multiple buffers', function()
      local buf1 = create_test_buffer()
      local buf2 = create_test_buffer()

      local win1 = create_test_window(buf1)
      local win2 = create_test_window(buf2)
      local win3 = create_test_window(buf1) -- Duplicate of buf1
      local win4 = create_test_window(buf2) -- Duplicate of buf2

      buf_fix_win.fix_to_win(buf1, function()
        return win1
      end)
      buf_fix_win.fix_to_win(buf2, function()
        return win2
      end)

      vim.cmd('doautocmd VimResized')

      vim.wait(100, function()
        return not vim.api.nvim_win_is_valid(win3) and not vim.api.nvim_win_is_valid(win4)
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
      assert.is_true(vim.api.nvim_win_is_valid(win2))
      assert.is_false(vim.api.nvim_win_is_valid(win3))
      assert.is_false(vim.api.nvim_win_is_valid(win4))
    end)

    it('should not close windows when no duplicates exist after VimResized', function()
      local buf = create_test_buffer()
      local win1 = create_test_window(buf)

      buf_fix_win.fix_to_win(buf, function()
        return win1
      end)

      vim.cmd('doautocmd VimResized')

      vim.wait(100, function()
        return false
      end)

      assert.is_true(vim.api.nvim_win_is_valid(win1))
    end)
  end)
end)
