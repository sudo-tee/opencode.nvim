local state = require('opencode.state')
local config = require('opencode.config')
local M = {}

function M.create_buf()
  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode', { buf = input_buf })
  return input_buf
end

function M._build_input_win_config()
  return {
    relative = 'editor',
    width = config.ui.window_width or 80,
    height = 3,
    col = 2,
    style = 'minimal',
    zindex = 41,
  } --[[@as vim.api.keyset.win_config]]
end

function M.create_window(windows)
  windows.input_win = vim.api.nvim_open_win(windows.input_buf, true, M._build_input_win_config())
end

function M.mounted(windows)
  windows = windows or state.windows
  if
    not windows
    or not windows.input_buf
    or not windows.input_win
    or not vim.api.nvim_win_is_valid(windows.input_win)
  then
    return false
  end

  return true
end

function M.close()
  if not M.mounted() then
    return
  end
  ---@cast state.windows { input_win: integer, input_buf: integer }

  pcall(vim.api.nvim_win_close, state.windows.input_win, true)
  pcall(vim.api.nvim_buf_delete, state.windows.input_buf, { force = true })
end

function M.handle_submit()
  local windows = state.windows
  if not windows or not M.mounted(windows) then
    return
  end
  ---@cast windows { input_buf: integer }

  local input_content = table.concat(vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false), '\n')
  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, {})
  vim.api.nvim_exec_autocmds('TextChanged', {
    buffer = windows.input_buf,
    modeline = false,
  })

  if input_content == '' then
    return
  end

  local key = config.get_key_for_function('input_window', 'slash_commands') or '/'
  if input_content:match('^' .. key) then
    M._execute_slash_command(input_content)
    return
  end

  require('opencode.core').send_message(input_content)
end

M._execute_slash_command = function(command)
  local slash_commands = require('opencode.api').get_slash_commands()
  local key = config.get_key_for_function('input_window', 'slash_commands') or '/'

  local cmd = command:sub(2):match('^%s*(.-)%s*$')
  if cmd == '' then
    return
  end
  local parts = vim.split(cmd, ' ')

  local command_cfg = vim.tbl_filter(function(c)
    return c.slash_cmd == key .. parts[1]
  end, slash_commands)[1]

  if command_cfg then
    command_cfg.fn(vim.list_slice(parts, 2))
  else
    vim.notify('Unknown command: ' .. cmd, vim.log.levels.WARN)
  end
end

function M.setup(windows)
  vim.api.nvim_set_option_value('winhighlight', config.ui.window_highlight, { win = windows.input_win })
  vim.api.nvim_set_option_value('wrap', config.ui.input.text.wrap, { win = windows.input_win })
  vim.api.nvim_set_option_value('signcolumn', 'yes', { win = windows.input_win })
  vim.api.nvim_set_option_value('cursorline', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('number', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('relativenumber', false, { win = windows.input_win })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = windows.input_buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = windows.input_buf })
  -- vim.b[windows.input_buf].completion = false
  vim.api.nvim_set_option_value('winfixbuf', true, { win = windows.input_win })
  vim.api.nvim_set_option_value('winfixheight', true, { win = windows.input_win })
  vim.api.nvim_set_option_value('winfixwidth', true, { win = windows.input_win })

  M.update_dimensions(windows)
  M.refresh_placeholder(windows)
  M.setup_keymaps(windows)
  M.recover_input(windows)

  require('opencode.ui.context_bar').render(windows)
end

function M.update_dimensions(windows)
  if not M.mounted(windows) then
    return
  end

  local total_width = vim.api.nvim_get_option_value('columns', {})
  local total_height = vim.api.nvim_get_option_value('lines', {})
  local width = math.floor(total_width * config.ui.window_width)
  local height = math.floor(total_height * config.ui.input_height)

  vim.api.nvim_win_set_config(windows.input_win, { width = width, height = height })
end

function M.refresh_placeholder(windows, input_lines)
  if not M.mounted(windows) then
    return
  end

  if not input_lines then
    input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  end
  if #input_lines == 1 and input_lines[1] == '' then
    local ns_id = vim.api.nvim_create_namespace('input_placeholder')
    local win_width = vim.api.nvim_win_get_width(windows.input_win)
    local padding = string.rep(' ', win_width)
    local slash_key = config.get_key_for_function('input_window', 'slash_commands')
    local mention_key = config.get_key_for_function('input_window', 'mention')
    local mention_file_key = config.get_key_for_function('input_window', 'mention_file')
    local context_key = config.get_key_for_function('input_window', 'context_items')

    vim.api.nvim_buf_set_extmark(windows.input_buf, ns_id, 0, 0, {
      virt_text = {
        { 'Type your prompt here... ', 'OpencodeHint' },
        { slash_key or '/', 'OpencodeInputLegend' },
        { ' commands ', 'OpencodeHint' },
        { mention_key or '@', 'OpencodeInputLegend' },
        { ' mentions ', 'OpencodeHint' },
        { mention_file_key or '~', 'OpencodeInputLegend' },
        { ' files ', 'OpencodeHint' },
        { context_key or '#', 'OpencodeInputLegend' },
        { ' context' .. padding, 'OpencodeHint' },
      },

      virt_text_pos = 'overlay',
    })
  else
    vim.api.nvim_buf_clear_namespace(windows.input_buf, vim.api.nvim_create_namespace('input_placeholder'), 0, -1)
  end
end

function M.clear_placeholder(windows)
  if not windows or not windows.input_buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(windows.input_buf, vim.api.nvim_create_namespace('input_placeholder'), 0, -1)
end

function M.recover_input(windows)
  M.set_content(state.input_content, windows)
  require('opencode.ui.mention').highlight_all_mentions(windows.input_buf)
end

function M.focus_input()
  if not M.mounted() then
    return
  end
  ---@cast state.windows { input_win: integer, input_buf: integer }

  vim.api.nvim_set_current_win(state.windows.input_win)

  local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
  if #lines == 1 and lines[1] == '' then
    require('opencode.ui.input_window').refresh_placeholder(state.windows)
  else
    require('opencode.ui.input_window').clear_placeholder(state.windows)
  end
end

function M.set_content(text, windows)
  windows = windows or state.windows
  if not M.mounted(windows) then
    return
  end
  ---@cast windows { input_win: integer, input_buf: integer }

  local lines = type(text) == 'table' and text or vim.split(tostring(text), '\n')

  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, lines)
end

function M.set_current_line(text, windows)
  windows = windows or state.windows
  if not M.mounted(windows) then
    return
  end

  vim.api.nvim_set_current_line(text)
end

function M.remove_mention(mention_name, windows)
  windows = windows or state.windows
  if not M.mounted(windows) then
    return
  end
  ---@cast windows { input_buf: integer }

  local lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    local mention_key = config.get_key_for_function('input_window', 'mention')
    local pattern = vim.pesc(mention_key .. mention_name)
    local updated_line = line:gsub(pattern, '')
    if updated_line ~= line then
      lines[i] = updated_line
    end
  end

  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, lines)
  require('opencode.ui.mention').highlight_all_mentions(windows.input_buf)
end

function M.is_empty()
  if not M.mounted() then
    return true
  end
  ---@cast state.windows { input_buf: integer }

  local lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
  return #lines == 0 or (#lines == 1 and lines[1] == '')
end

function M.setup_keymaps(windows)
  local keymap = require('opencode.keymap')
  keymap.setup_window_keymaps(config.keymap.input_window, windows.input_buf)
end

function M.setup_autocmds(windows, group)
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      M.refresh_placeholder(windows)
      state.last_focused_opencode_window = 'input'
      require('opencode.ui.context_bar').render()
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = windows.input_buf,
    callback = function()
      local input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      state.input_content = input_lines
      M.refresh_placeholder(windows, input_lines)
      require('opencode.ui.context_bar').render()
    end,
  })

  state.subscribe('current_permission', function()
    require('opencode.keymap').toggle_permission_keymap(windows.input_buf)
  end)
end

return M
