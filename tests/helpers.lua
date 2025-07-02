-- tests/helpers.lua
-- Helper functions for testing

local M = {}

-- Create a temporary file with content
function M.create_temp_file(content)
  local tmp_file = vim.fn.tempname()
  local file = io.open(tmp_file, "w")
  file:write(content or "Test file content")
  file:close()
  return tmp_file
end

-- Clean up temporary file
function M.delete_temp_file(file)
  vim.fn.delete(file)
end

-- Open a buffer for a file
function M.open_buffer(file)
  vim.cmd("edit " .. file)
  return vim.api.nvim_get_current_buf()
end

-- Close a buffer
function M.close_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.cmd, "bdelete! " .. bufnr)
  end
end

-- Set visual selection programmatically
function M.set_visual_selection(start_line, start_col, end_line, end_col)
  -- Enter visual mode
  vim.cmd("normal! " .. start_line .. "G" .. start_col .. "lv" .. end_line .. "G" .. end_col .. "l")
end

-- Reset editor state
function M.reset_editor()
  -- Clear all buffers
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    -- Skip non-existing or invalid buffers
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.cmd, "bdelete! " .. bufnr)
    end
  end
  -- Reset any other editor state as needed
  pcall(vim.cmd, "silent! %bwipeout!")
end

-- Mock input function
function M.mock_input(return_value)
  local original_input = vim.fn.input
  vim.fn.input = function(...)
    return return_value
  end
  return function()
    vim.fn.input = original_input
  end
end

-- Mock notification function
function M.mock_notify()
  local notifications = {}
  local original_notify = vim.notify
  
  vim.notify = function(msg, level, opts)
    table.insert(notifications, {
      msg = msg,
      level = level,
      opts = opts
    })
  end
  
  return {
    reset = function()
      vim.notify = original_notify
    end,
    get_notifications = function()
      return notifications
    end,
    clear = function()
      notifications = {}
    end
  }
end

return M