local M = {}

local INPUT_PLACEHOLDER = 'Plan, search, ask, / for custom commands'
local config = require('opencode.config').get()
local state = require('opencode.state')
local ui_util = require('opencode.ui.util')
local ui = require('opencode.ui.ui')
local api = require('opencode.api')

M.floating_win_opts = {
  relative = 'editor',
  style = 'minimal',
  border = 'rounded',
  zindex = 50,
  width = 1,
  height = 1,
  col = 0,
  row = 0,
}

function M.setup_options(windows)
  -- Input window/buffer options
  vim.api.nvim_set_option_value('winhighlight', config.ui.window_highlight, { win = windows.input_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { win = windows.input_win })
  vim.api.nvim_set_option_value('cursorline', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('number', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = windows.input_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = windows.input_buf })
  vim.b[windows.input_buf].completion = false

  -- Output window/buffer options
  vim.api.nvim_set_option_value('winhighlight', config.ui.window_highlight, { win = windows.output_win })
  vim.api.nvim_set_option_value('wrap', true, { win = windows.output_win })
  vim.api.nvim_set_option_value('number', false, { win = windows.output_win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = windows.output_win })
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = windows.output_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = windows.output_buf })
end

function M.refresh_placeholder(windows, input_lines)
  -- show placeholder if input buffer is empty - otherwise clear it
  if not input_lines then
    input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  end

  if #input_lines == 1 and input_lines[1] == '' then
    local ns_id = vim.api.nvim_create_namespace('input-placeholder')
    local win_width = vim.api.nvim_win_get_width(windows.input_win)
    local placeholder_len = vim.fn.strwidth(INPUT_PLACEHOLDER)
    local padding = string.rep(' ', win_width - placeholder_len)
    vim.api.nvim_buf_set_extmark(windows.input_buf, ns_id, 0, 0, {
      virt_text = { { INPUT_PLACEHOLDER .. padding, 'Comment' } },
      virt_text_pos = 'overlay',
    })
  else
    vim.api.nvim_buf_clear_namespace(windows.input_buf, vim.api.nvim_create_namespace('input-placeholder'), 0, -1)
  end
end

function M.setup_autocmds(windows)
  local group = vim.api.nvim_create_augroup('OpencodeWindows', { clear = true })

  -- Output window autocmds
  vim.api.nvim_create_autocmd({ 'WinEnter', 'BufEnter' }, {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      vim.cmd('stopinsert')
      state.last_focused_opencode_window = 'output'
      M.refresh_placeholder(windows)
    end,
  })

  -- Input window autocmds
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      M.refresh_placeholder(windows)
      state.last_focused_opencode_window = 'input'
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = windows.input_buf,
    callback = function()
      local input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      state.input_content = input_lines
      M.refresh_placeholder(windows, input_lines)
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = group,
    pattern = tostring(windows.input_win) .. ',' .. tostring(windows.output_win),
    callback = function(opts)
      -- Get the window that was closed
      local closed_win = tonumber(opts.match)
      -- If either window is closed, close both
      if closed_win == windows.input_win or closed_win == windows.output_win then
        vim.schedule(function()
          require('opencode.ui.ui').close_windows(windows)
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    pattern = '*',
    callback = function()
      if not require('opencode.ui.ui').is_opencode_focused() then
        require('opencode.context').load()
        state.last_code_win_before_opencode = vim.api.nvim_get_current_win()
      end
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      state.last_input_window_position = vim.api.nvim_win_get_cursor(0)
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = windows.output_buf,
    callback = function()
      state.last_output_window_position = vim.api.nvim_win_get_cursor(0)
    end,
  })
end

function M.configure_window_dimensions(windows)
  if config.ui.floating then
    M.configure_floating_window_dimensions(windows)
  end
  local total_width = vim.api.nvim_get_option_value('columns', {})
  local total_height = vim.api.nvim_get_option_value('lines', {})
  local width = math.floor(total_width * config.ui.window_width)
  local height = math.floor(total_height * config.ui.input_height)

  vim.api.nvim_win_set_config(windows.output_win, { width = width })
  vim.api.nvim_win_set_config(windows.input_win, { width = width, height = height })
end

function M.configure_floating_window_dimensions(windows)
  local total_width = vim.api.nvim_get_option_value('columns', {})
  local total_height = vim.api.nvim_get_option_value('lines', {})
  local is_fullscreen = config.ui.fullscreen

  local width
  if is_fullscreen then
    width = total_width
  else
    width = math.floor(total_width * config.ui.window_width)
  end

  local layout = config.ui.layout
  local total_usable_height
  local row, col

  if layout == 'center' then
    -- Use a smaller height for floating; allow an optional `floating_height` factor (e.g. 0.8).
    local fh = config.ui.floating_height
    total_usable_height = math.floor(total_height * fh)
    -- Center the floating window vertically and horizontally.
    row = math.floor((total_height - total_usable_height) / 2)
    col = is_fullscreen and 0 or math.floor((total_width - width) / 2)
  else
    -- "right" layout uses the original full usable height.
    total_usable_height = total_height - 3
    row = 0
    col = is_fullscreen and 0 or (total_width - width)
  end

  local input_height = math.floor(total_usable_height * config.ui.input_height)
  local output_height = total_usable_height - input_height - 2

  vim.api.nvim_win_set_config(windows.output_win, {
    relative = 'editor',
    width = width,
    height = output_height,
    col = col,
    row = row,
  })

  vim.api.nvim_win_set_config(windows.input_win, {
    relative = 'editor',
    width = width,
    height = input_height,
    col = col,
    row = row + output_height + 2,
  })
end

function M.setup_resize_handler(windows)
  local function cb()
    M.configure_window_dimensions(windows)
    require('opencode.ui.topbar').render()
  end

  vim.api.nvim_create_autocmd('VimResized', {
    group = vim.api.nvim_create_augroup('OpencodeResize', { clear = true }),
    callback = cb,
  })
end

local function recover_input(windows)
  local input_content = state.input_content
  require('opencode.ui.ui').write_to_input(input_content, windows)
  require('opencode.ui.mention').highlight_all_mentions(windows.input_buf)
end

function M.setup_after_actions(windows)
  recover_input(windows)
end

local function handle_submit()
  local windows = state.windows
  local input_content = table.concat(vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false), '\n')
  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, {})
  vim.api.nvim_exec_autocmds('TextChanged', {
    buffer = windows.input_buf,
    modeline = false,
  })

  -- Switch to the output window
  vim.api.nvim_set_current_win(windows.output_win)

  -- Always scroll to the bottom when submitting a new prompt
  local line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  vim.api.nvim_win_set_cursor(windows.output_win, { line_count, 0 })

  -- Run the command with the input content
  require('opencode.core').run(input_content)
end

function M.setup_keymaps(windows)
  local map = require('opencode.keymap').buf_keymap
  local nav = require('opencode.ui.navigation')
  local core = require('opencode.core')

  local keymaps = config.keymap.window
  local input_buf = windows.input_buf
  local output_buf = windows.output_buf
  local both_bufs = { input_buf, output_buf }
  local nav_history = ui_util.navigate_history

  -- Submit handlers
  map(keymaps.submit, handle_submit, input_buf, 'n')
  map(keymaps.submit_insert, handle_submit, input_buf, 'i')

  -- Close handlers
  map(keymaps.close, api.close, both_bufs, 'n')

  -- Message navigation
  map(keymaps.next_message, nav.goto_next_message, both_bufs, 'n')
  map(keymaps.prev_message, nav.goto_prev_message, both_bufs, 'n')

  map(keymaps.stop, api.stop, both_bufs, { 'n', 'i' })

  map(keymaps.mention_file, core.add_file_to_context, input_buf, 'i')

  map(keymaps.toggle_pane, api.toggle_pane, both_bufs, { 'n', 'i' })

  map(keymaps.focus_input, ui.focus_input, output_buf, 'n')

  map(keymaps.prev_prompt_history, nav_history(keymaps.prev_prompt_history, 'prev'), input_buf, { 'n', 'i' })
  map(keymaps.next_prompt_history, nav_history(keymaps.next_prompt_history, 'next'), input_buf, { 'n', 'i' })

  map(keymaps.switch_mode, api.switch_to_next_mode, input_buf, { 'n', 'i' })
  map(keymaps.switch_mode, api.switch_to_next_mode, output_buf, 'n')

  if config.debug.enabled then
    local debug_helper = require('opencode.ui.debug_helper')
    map(keymaps.debug_output, debug_helper.debug_output, output_buf, 'n')
    map(keymaps.debug_message, debug_helper.debug_message, output_buf, 'n')
  end
end

return M
