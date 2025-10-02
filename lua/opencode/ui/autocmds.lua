local input_window = require('opencode.ui.input_window')
local output_window = require('opencode.ui.output_window')
local M = {}

local last_update = 0

function M.setup_autocmds(windows)
  local group = vim.api.nvim_create_augroup('OpencodeWindows', { clear = true })
  input_window.setup_autocmds(windows, group)
  output_window.setup_autocmds(windows, group)

  -- Only keep shared autocmds here (e.g., WinClosed, CursorHold for all windows)
  local wins = { windows.input_win, windows.output_win, windows.footer_win }
  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = table.concat(wins, ','),
    callback = function(opts)
      local closed_win = tonumber(opts.match)
      if vim.tbl_contains(wins, closed_win) then
        vim.schedule(function()
          require('opencode.ui.ui').close_windows(windows)
        end)
      end
    end,
  })

  -- Based on CursorHold, update context if user is not focused on opencode window
  vim.api.nvim_create_autocmd('CursorHold', {
    group = group,
    pattern = '*',
    callback = function()
      local now = vim.uv.now()
      if now - last_update < 1000 then
        return
      end
      last_update = now
      if not require('opencode.ui.ui').is_opencode_focused() then
        require('opencode.context').load()
        require('opencode.state').last_code_win_before_opencode = vim.api.nvim_get_current_win()
      end
    end,
  })
end

function M.setup_resize_handler(windows)
  local resize_group = vim.api.nvim_create_augroup('OpencodeResize', { clear = true })
  vim.api.nvim_create_autocmd('VimResized', {
    group = resize_group,
    callback = function()
      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
      require('opencode.ui.input_window').update_dimensions(windows)
      require('opencode.ui.output_window').update_dimensions(windows)
    end,
  })

  vim.api.nvim_create_autocmd('WinResized', {
    group = resize_group,
    callback = function(args)
      local win = tonumber(args.match)
      if not win or not vim.api.nvim_win_is_valid(win) or not output_window.mounted() then
        return
      end

      local floating = vim.api.nvim_win_get_config(win).relative ~= ''
      if floating then
        return
      end

      require('opencode.ui.topbar').render()
      require('opencode.ui.footer').update_window(windows)
    end,
  })
end

return M
