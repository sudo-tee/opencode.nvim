local M = {}

---@type string|nil
local saved_text = nil

---@class InlineInputOpts
---@field win integer            -- window to anchor against
---@field row integer            -- 0-indexed row in that window's buffer
---@field col integer            -- 0-indexed col in that window's buffer
---@field min_width? integer
---@field max_width? integer
---@field title? string           -- window border title
---@field on_submit fun(text: string)
---@field on_cancel fun()

---Open a floating, prompt-buffer-backed text input anchored at a specific
---(row, col) inside an existing window's buffer, so it visually appears
---"inline" at that position rather than as a separate cmdline prompt.
---@param opts InlineInputOpts
---@return { close: fun(), win: integer, buf: integer }
function M.open(opts)
  local min_width = opts.min_width or 50
  local max_width = opts.max_width or 75

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'prompt'
  vim.bo[buf].bufhidden = 'wipe'
  vim.fn.prompt_setprompt(buf, '')

  if saved_text and saved_text ~= '' then
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { saved_text })
    saved_text = nil
  end

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'win',
    win = opts.win,
    bufpos = { opts.row, opts.col },
    width = min_width,
    height = 1,
    style = 'minimal',
    border = 'rounded',
    title = opts.title and (' ' .. opts.title .. ' ') or nil,
    title_pos = 'left',
    zindex = 60,
  })

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

  vim.fn.prompt_setcallback(buf, function(text)
    close()
    if text ~= '' then
      saved_text = nil
      opts.on_submit(text)
    else
      opts.on_cancel()
    end
  end)

  vim.keymap.set('i', '<C-c>', function()
    saved_text = nil
    close()
    opts.on_cancel()
  end, { buffer = buf, silent = true, nowait = true })

  vim.keymap.set('n', '<Esc>', function()
    saved_text = nil
    close()
    opts.on_cancel()
  end, { buffer = buf, silent = true, nowait = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = buf,
    callback = function()
      if not vim.api.nvim_win_is_valid(win) then
        return
      end
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
      local width = math.min(max_width, math.max(min_width, vim.fn.strdisplaywidth(line) + 2))
      vim.api.nvim_win_set_config(win, { width = width })
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
        local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
        if line ~= '' then
          saved_text = line
        end
        close()
        opts.on_cancel()
      end
    end,
  })

  vim.schedule(function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      vim.cmd.startinsert()
    end
  end)

  return { close = close, win = win, buf = buf }
end

return M
