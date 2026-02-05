--- Prevents a buffer from appearing in multiple windows (opposite of 'winfixbuf')
---
--- This module solves the problem where buffers can appear in multiple windows
--- despite having 'winfixbuf' set. The 'winfixbuf' option prevents a window from
--- changing buffers, but doesn't prevent a buffer from appearing in multiple windows.
---
local M = {}
local buff_to_win_map = {}
local global_autocmd_setup = false

local function close_duplicates(buf, get_win)
  local intended = get_win()
  if not intended or not vim.api.nvim_win_is_valid(intended) then
    return
  end

  local wins = vim.fn.win_findbuf(buf)
  if #wins <= 1 then
    return
  end

  for _, win in ipairs(wins) do
    if win ~= intended and vim.api.nvim_win_is_valid(win) then
      vim.schedule(function()
        pcall(vim.api.nvim_win_close, win, true)
      end)
    end
  end
end

local check_all_buffers = vim.schedule_wrap(function()
  for buf, get_win in pairs(buff_to_win_map) do
    if vim.api.nvim_buf_is_valid(buf) then
      close_duplicates(buf, get_win)
    else
      buff_to_win_map[buf] = nil
    end
  end
end)

local function setup()
  if global_autocmd_setup then
    return
  end
  global_autocmd_setup = true

  local augroup = vim.api.nvim_create_augroup('OpenCodeBufFixWin', { clear = false })
  vim.api.nvim_create_autocmd({ 'WinNew', 'VimResized' }, {
    group = augroup,
    callback = check_all_buffers,
  })
  vim.api.nvim_create_autocmd('BufDelete', {
    callback = function(args)
      if args and args.buf then
        buff_to_win_map[args.buf] = nil
      end
    end,
  })
end

--- Protect a buffer from appearing in multiple windows
---@param buf integer Buffer number
---@param get_intended_window fun(): integer? Function returning intended window ID
function M.fix_to_win(buf, get_intended_window)
  setup()

  buff_to_win_map[buf] = get_intended_window
  local augroup = vim.api.nvim_create_augroup('OpenCodeBufFixWin_' .. buf, { clear = true })
  vim.api.nvim_create_autocmd('BufWinEnter', {
    group = augroup,
    buffer = buf,
    callback = function()
      close_duplicates(buf, get_intended_window)
    end,
  })
end

return M
