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
  local col_shift = math.max(0, anchor.col + width + 1 - vim.o.columns)
  local row_shift = math.max(0, anchor.row + 3 - vim.o.lines)
  local max_height = math.max(1, vim.o.lines - anchor.row + row_shift - 2)
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
    row = 1 - row_shift,
    col = -col_shift,
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
  local win_closed_autocmd
  local function delete_win_closed_autocmd()
    if win_closed_autocmd then
      pcall(vim.api.nvim_del_autocmd, win_closed_autocmd)
      win_closed_autocmd = nil
    end
  end

  local function close()
    if closed then
      return
    end
    closed = true
    delete_win_closed_autocmd()
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

  -- hist_index 0 = at the in-progress text; N >= 1 = Nth-from-newest in
  -- vim's "input" history (shared with vim.fn.input).
  local hist_index = 0
  local hist_snapshot

  local function buf_set(text)
    local lines = vim.split(text or '', '\n', { plain = true })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    if vim.api.nvim_win_is_valid(win) then
      local last = lines[#lines] or ''
      pcall(vim.api.nvim_win_set_cursor, win, { math.max(1, #lines), #last })
    end
    -- Replacing all lines can drop the editor out of insert mode; re-enter
    -- so <C-n>/typing keeps working.
    vim.schedule(function()
      if not closed and vim.api.nvim_win_is_valid(win) then
        pcall(vim.cmd.startinsert)
      end
    end)
    resize_height()
  end

  local function hist_prev()
    local entry = vim.fn.histget('input', -(hist_index + 1))
    if entry == '' then
      return
    end
    if hist_index == 0 then
      hist_snapshot = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
    end
    hist_index = hist_index + 1
    buf_set(entry)
  end

  local function hist_next()
    if hist_index == 0 then
      return
    end
    if hist_index == 1 then
      buf_set(hist_snapshot or '')
      hist_index = 0
      hist_snapshot = nil
      return
    end
    hist_index = hist_index - 1
    buf_set(vim.fn.histget('input', -hist_index))
  end

  vim.fn.prompt_setcallback(buf, function(text)
    close()
    if text == '' then
      return opts.on_cancel()
    end
    vim.fn.histadd('input', text)
    opts.on_submit(text)
  end)

  vim.keymap.set('i', '<C-c>', function()
    cancel_with_draft()
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set('n', '<Esc>', function()
    cancel_with_draft()
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set('i', '<C-p>', hist_prev, { buffer = buf, silent = true, nowait = true })
  vim.keymap.set('i', '<C-n>', hist_next, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = buf,
    callback = function()
      vim.schedule(resize_height)
    end,
  })

  win_closed_autocmd = vim.api.nvim_create_autocmd('WinClosed', {
    pattern = { tostring(opts.win), tostring(win) },
    callback = function(event)
      if closed then
        return
      end
      if tonumber(event.match) == opts.win then
        cancel_with_draft()
        return
      end
      closed = true
      delete_win_closed_autocmd()
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
