local M = {}

M.__diff_tab = nil

function M.close_diff_tab()
  if M.__diff_tab and vim.api.nvim_tabpage_is_valid(M.__diff_tab) then
    pcall(vim.api.nvim_del_augroup_by_name, 'OpencodeDiffCleanup' .. M.__diff_tab)
    local windows = vim.api.nvim_tabpage_list_wins(M.__diff_tab)
    local buffers = {}
    for _, win in ipairs(windows) do
      local buf = vim.api.nvim_win_get_buf(win)
      table.insert(buffers, buf)
    end
    vim.api.nvim_set_current_tabpage(M.__diff_tab)
    pcall(vim.cmd, 'tabclose')
    for _, buf in ipairs(buffers) do
      if vim.api.nvim_buf_is_valid(buf) then
        local visible = false
        for _, win in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(win) == buf then
            visible = true
            break
          end
        end
        if not visible then
          pcall(vim.api.nvim_buf_delete, buf, { force = true })
        end
      end
    end
  end
  M.__diff_tab = nil
end

function M.open_diff_tab(file_path, snapshot_path, file_type)
  M.close_diff_tab()
  local is_local_file = vim.startswith(file_path, vim.fn.getcwd() .. '/')
  file_type = file_type or vim.fn.fnamemodify(file_path, ':e')
  vim.cmd('tabnew')
  M.__diff_tab = vim.api.nvim_get_current_tabpage()
  if snapshot_path then
    vim.cmd('edit ' .. vim.fn.fnameescape(snapshot_path))
    vim.cmd('setlocal readonly buftype=nofile nomodifiable')
    vim.cmd('setlocal filetype=' .. file_type)
    vim.cmd('diffthis')
    vim.cmd('vsplit ' .. vim.fn.fnameescape(file_path))
    vim.cmd('diffthis')
    if not is_local_file then
      vim.cmd('setlocal readonly buftype=nofile nomodifiable')
      vim.cmd('setlocal filetype=' .. file_type)
    end
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(file_path))
    vim.cmd('setlocal filetype=' .. file_type)
  end
  local augroup = vim.api.nvim_create_augroup('OpencodeGitDiffCleanup' .. M.__diff_tab, { clear = true })
  local tab_windows = vim.api.nvim_tabpage_list_wins(M.__diff_tab)
  vim.api.nvim_create_autocmd('WinClosed', {
    group = augroup,
    pattern = tostring(tab_windows[1]) .. ',' .. tostring(tab_windows[2]),
    callback = function()
      M.close_diff_tab()
    end,
  })
end

return M
