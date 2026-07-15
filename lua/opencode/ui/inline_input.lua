local M = {}

---@class InlineInputOpts
---@field win integer            -- window to anchor against
---@field row integer            -- 0-indexed row in that window's buffer
---@field col integer            -- 0-indexed col in that window's buffer
---@field title? string           -- window border title
---@field initial_text? string
---@field on_submit fun(text: string)
---@field on_cancel fun()
---@field on_leave? fun(text: string)

---Open a floating, prompt-buffer-backed text input anchored at a specific
---(row, col) inside an existing window's buffer, so it visually appears
---"inline" at that position rather than as a separate cmdline prompt.
---@param opts InlineInputOpts
---@return { close: fun(), win: integer, buf: integer }
function M.open(opts)
  local anchor = vim.fn.screenpos(opts.win, opts.row + 1, opts.col + 1)
  local width = math.max(1, math.min(50, vim.o.columns - anchor.col - 1))
  local max_height = math.max(1, vim.o.lines - anchor.row - 2)
  local initial_lines = opts.initial_text and vim.split(opts.initial_text, '\n', { plain = true }) or nil

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'prompt'
  vim.bo[buf].bufhidden = 'wipe'
  vim.fn.prompt_setprompt(buf, '')

  if initial_lines then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, initial_lines)
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = opts.win,
    bufpos = { opts.row, opts.col },
    width = width,
    height = 1,
    style = 'minimal',
    border = 'rounded',
    title = opts.title and (' ' .. opts.title .. ' ') or nil,
    title_pos = opts.title and 'left' or nil,
    zindex = 60,
  })
  vim.wo[win].wrap = true

  local function resize_height()
    if not vim.api.nvim_win_is_valid(win) then
      return
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    local height = vim.api.nvim_win_text_height(win, { start_row = 0, end_row = line_count - 1 }).all
    vim.api.nvim_win_set_config(win, { height = math.min(max_height, math.max(1, height)) })
  end

  resize_height()

  local closed = false
  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(opts.win) then
      vim.api.nvim_set_current_win(opts.win)
    end
    vim.schedule(function()
      pcall(vim.cmd.stopinsert)
    end)
  end

  local function cancel_with_draft()
    local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    close()
    if opts.on_leave then
      opts.on_leave(text)
    end
    opts.on_cancel()
  end

  vim.fn.prompt_setcallback(buf, function(text)
    close()
    if text ~= '' then
      opts.on_submit(text)
    else
      opts.on_cancel()
    end
  end)

  vim.keymap.set('i', '<C-c>', function()
    cancel_with_draft()
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set('n', '<Esc>', function()
    cancel_with_draft()
  end, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      vim.schedule(resize_height)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    pattern = tostring(win),
    callback = function()
      if closed then
        return
      end
      closed = true
      if vim.api.nvim_win_is_valid(opts.win) then
        vim.api.nvim_set_current_win(opts.win)
      end
      vim.schedule(function()
        pcall(vim.cmd.stopinsert)
      end)
      opts.on_cancel()
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = buf,
    callback = function()
      if not closed then
        cancel_with_draft()
      end
    end,
  })

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd.startinsert()
      if initial_lines then
        local last_line = initial_lines[#initial_lines]
        vim.api.nvim_win_set_cursor(win, { #initial_lines, vim.fn.strlen(last_line) })
      end
    end
  end)

  return { close = close, win = win, buf = buf }
end

return M
