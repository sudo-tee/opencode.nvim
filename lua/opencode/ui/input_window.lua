local state = require('opencode.state')
local config = require('opencode.config')
local M = {}

-- Track hidden state
M._hidden = false
-- Flag to prevent WinClosed autocmd from closing all windows during toggle
M._toggling = false
M._resize_scheduled = false

-- Cache namespace ID to avoid repeated creation
local placeholder_ns = vim.api.nvim_create_namespace('input_placeholder')

local function get_content_height(windows)
  local line_count = vim.api.nvim_buf_line_count(windows.input_buf)
  if line_count <= 0 then
    return 1
  end
  if config.ui.input.text.wrap then
    local ok, result = pcall(vim.api.nvim_win_text_height, windows.input_win, {
      start_row = 0,
      end_row = math.max(0, line_count - 1),
    })
    if ok and result and result.all then
      return result.all
    end
  end

  return line_count
end

local function get_winbar_height(windows)
  local ok, winbar = pcall(vim.api.nvim_get_option_value, 'winbar', { win = windows.input_win })
  if ok and type(winbar) == 'string' and winbar ~= '' then
    return 1
  end

  return 0
end

local function calculate_height(windows)
  local total_height = vim.api.nvim_get_option_value('lines', {})
  local min_height = math.max(1, math.floor(total_height * config.ui.input.min_height))
  local max_height = math.max(min_height, math.floor(total_height * config.ui.input.max_height))
  local content_height = get_content_height(windows) + get_winbar_height(windows)
  return math.min(max_height, math.max(min_height, content_height))
end

local function apply_dimensions(windows, height)
  if config.ui.position == 'current' then
    pcall(vim.api.nvim_win_set_height, windows.input_win, height)
    return
  end

  local total_width = vim.api.nvim_get_option_value('columns', {})
  local width_ratio = state.pre_zoom_width and config.ui.zoom_width or config.ui.window_width
  local width = math.floor(total_width * width_ratio)

  vim.api.nvim_win_set_config(windows.input_win, { width = width, height = height })
end

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

---@return_cast windows { input_win: integer, input_buf: integer }
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

---Handle submit action from input window
---@return boolean true if a message was sent to the AI, false otherwise
function M.handle_submit()
  local windows = state.windows
  if not windows or not M.mounted(windows) then
    return false
  end
  ---@cast windows { input_buf: integer }

  local input_content = table.concat(vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false), '\n')
  vim.api.nvim_buf_set_lines(windows.input_buf, 0, -1, false, {})
  vim.api.nvim_exec_autocmds('TextChanged', {
    buffer = windows.input_buf,
    modeline = false,
  })

  if input_content == '' then
    return false
  end

  if input_content:match('^!') then
    M._execute_shell_command(input_content:sub(2))
    return false
  end

  local key = config.get_key_for_function('input_window', 'slash_commands') or '/'
  if input_content:match('^' .. key) then
    M._execute_slash_command(input_content)
    return false
  end

  require('opencode.core').send_message(input_content)
  return true
end

M._execute_shell_command = function(command)
  local cmd = command:match('^%s*(.-)%s*$')
  if cmd == '' then
    return
  end

  local shell = vim.o.shell
  local shell_cmd = { shell, '-c', cmd }

  vim.system(shell_cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        vim.notify('Command failed with exit code ' .. result.code, vim.log.levels.ERROR)
      end

      local output = result.stdout or ''
      if result.stderr and result.stderr ~= '' then
        output = output .. '\n' .. result.stderr
      end

      M._prompt_add_to_context(cmd, output, result.code)
    end)
  end)
end

M._prompt_add_to_context = function(cmd, output, exit_code)
  local output_window = require('opencode.ui.output_window')
  if not output_window.mounted() then
    return
  end

  local formatted_output = string.format('$ %s\n%s', cmd, output)
  local lines = vim.split(formatted_output, '\n')

  output_window.set_lines(lines)

  local picker = require('opencode.ui.picker')
  picker.select({ 'Yes', 'No' }, {
    prompt = 'Add command + output to context?',
  }, function(choice)
    if choice == 'Yes' then
      local message = string.format('Command: `%s`\nExit code: %d\nOutput:\n```\n%s```', cmd, exit_code, output)
      M._append_to_input(message)
    end
    output_window.clear()
    require('opencode.ui.input_window').focus_input()
  end)
end

M._append_to_input = function(text)
  if M._hidden then
    M._show()
  end

  if not M.mounted() then
    return
  end
  ---@cast state.windows -nil

  local current_lines = vim.api.nvim_buf_get_lines(state.windows.input_buf, 0, -1, false)
  local new_lines = vim.split(text, '\n')

  if #current_lines == 1 and current_lines[1] == '' then
    vim.api.nvim_buf_set_lines(state.windows.input_buf, 0, -1, false, new_lines)
  else
    vim.api.nvim_buf_set_lines(state.windows.input_buf, -1, -1, false, { '', '---', '' })
    vim.api.nvim_buf_set_lines(state.windows.input_buf, -1, -1, false, new_lines)
  end

  M.refresh_placeholder(state.windows)
  require('opencode.ui.mention').highlight_all_mentions(state.windows.input_buf)

  local line_count = vim.api.nvim_buf_line_count(state.windows.input_buf)
  vim.api.nvim_win_set_cursor(state.windows.input_win, { line_count, 0 })
end

M._execute_slash_command = function(command)
  local slash_commands = require('opencode.api').get_slash_commands():await()
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
    local args = #parts > 1 and vim.list_slice(parts, 2) or nil
    command_cfg.fn(args)
  else
    vim.notify('Unknown command: ' .. cmd, vim.log.levels.WARN)
  end
end

local function set_win_option(option, value, windows)
  windows = windows or state.windows
  vim.api.nvim_set_option_value(option, value, { win = windows.input_win, scope = 'local' })
end

local function set_buf_option(option, value, windows)
  windows = windows or state.windows
  vim.api.nvim_set_option_value(option, value, { buf = windows.input_buf })
end

function M.setup(windows)
  if config.ui.input.text.wrap then
    set_win_option('wrap', true, windows)
    set_win_option('linebreak', true, windows)
  end

  set_buf_option('filetype', 'opencode', windows)
  set_win_option('winhighlight', config.ui.window_highlight, windows)
  set_win_option('signcolumn', 'yes', windows)
  set_win_option('cursorline', false, windows)
  set_win_option('number', false, windows)
  set_win_option('relativenumber', false, windows)
  set_buf_option('buftype', 'nofile', windows)
  set_buf_option('swapfile', false, windows)

  if config.ui.position ~= 'current' then
    set_win_option('winfixbuf', true, windows)
  end
  set_win_option('winfixheight', true, windows)
  set_win_option('winfixwidth', true, windows)

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

  local height = calculate_height(windows)
  apply_dimensions(windows, height)
end

function M.schedule_resize(windows)
  windows = windows or state.windows
  if not M.mounted(windows) or M._resize_scheduled then
    return
  end

  M._resize_scheduled = true
  vim.schedule(function()
    M._resize_scheduled = false
    if M.mounted(windows) then
      M.update_dimensions(windows)
    end
  end)
end

function M.refresh_placeholder(windows, input_lines)
  if not M.mounted(windows) then
    return
  end

  if not input_lines then
    input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
  end
  if #input_lines == 1 and input_lines[1] == '' then
    local ns_id = placeholder_ns
    local win_width = vim.api.nvim_win_get_width(windows.input_win)
    local padding = string.rep(' ', win_width)
    local slash_key = config.get_key_for_function('input_window', 'slash_commands')
    local mention_key = config.get_key_for_function('input_window', 'mention')
    local mention_file_key = config.get_key_for_function('input_window', 'mention_file')
    local context_key = config.get_key_for_function('input_window', 'context_items')

    local virt_text = {
      { 'Type your prompt here... ', 'OpencodeHint' },
      { '!', 'OpencodeInputLegend' },
      { ' shell ', 'OpencodeHint' },
    }
    if slash_key then
      table.insert(virt_text, { slash_key, 'OpencodeInputLegend' })
      table.insert(virt_text, { ' commands ', 'OpencodeHint' })
    end
    if mention_key then
      table.insert(virt_text, { mention_key, 'OpencodeInputLegend' })
      table.insert(virt_text, { ' mentions ', 'OpencodeHint' })
    end
    if mention_file_key then
      table.insert(virt_text, { mention_file_key, 'OpencodeInputLegend' })
      table.insert(virt_text, { ' files ', 'OpencodeHint' })
    end
    if context_key then
      table.insert(virt_text, { context_key, 'OpencodeInputLegend' })
      table.insert(virt_text, { ' context', 'OpencodeHint' })
    end
    table.insert(virt_text, { padding, 'OpencodeHint' })
    vim.api.nvim_buf_set_extmark(windows.input_buf, ns_id, 0, 0, {
      virt_text = virt_text,
      virt_text_pos = 'overlay',
    })
  else
    vim.api.nvim_buf_clear_namespace(windows.input_buf, placeholder_ns, 0, -1)
  end
end

function M.clear_placeholder(windows)
  if not windows or not windows.input_buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(windows.input_buf, placeholder_ns, 0, -1)
end

function M.recover_input(windows)
  M.set_content(state.input_content, windows)
  require('opencode.ui.mention').highlight_all_mentions(windows.input_buf)
  M.update_dimensions(windows)
end

function M.focus_input()
  if M._hidden then
    M._show()
    return
  end

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
  if not windows or not windows.input_buf then
    return
  end

  local lines = type(text) == 'table' and text or vim.split(tostring(text), '\n')
  local has_content = #lines > 1 or (lines[1] and lines[1] ~= '')

  if has_content and M._hidden then
    M._show()
    windows = state.windows
  end

  if not M.mounted(windows) then
    return
  end
  ---@cast windows { input_win: integer, input_buf: integer }

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

local keymaps_set_for_buf = {}

function M.setup_keymaps(windows)
  if keymaps_set_for_buf[windows.input_buf] then
    return
  end
  keymaps_set_for_buf[windows.input_buf] = true

  local keymap = require('opencode.keymap')
  keymap.setup_window_keymaps(config.keymap.input_window, windows.input_buf, true)
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

  vim.api.nvim_create_autocmd('WinLeave', {
    group = group,
    buffer = windows.input_buf,
    callback = function()
      -- Auto-hide input window when auto_hide is enabled and focus leaves
      -- Don't hide if displaying a route (slash command output like /help)
      -- Don't hide if input contains content
      if
        config.ui.input.auto_hide
        and not M.is_hidden()
        and not state.display_route
        and #state.input_content == 1
        and state.input_content[1] == ''
      then
        M._hide()
      end
    end,
  })

  vim.api.nvim_create_autocmd({ 'TextChanged', 'TextChangedI' }, {
    buffer = windows.input_buf,
    callback = function()
      local input_lines = vim.api.nvim_buf_get_lines(windows.input_buf, 0, -1, false)
      state.input_content = input_lines
      M.refresh_placeholder(windows, input_lines)
      require('opencode.ui.context_bar').render()
      M.schedule_resize(windows)
    end,
  })
end

---Toggle the input window visibility (hide/show)
---When hidden, the input window is closed entirely
---When shown, the input window is recreated
function M.toggle()
  local windows = state.windows
  if not windows then
    return
  end

  if M._hidden then
    M._show()
  else
    M._hide()
  end
end

---Hide the input window by closing it
function M._hide()
  local windows = state.windows
  if not M.mounted(windows) then
    return
  end

  local output_window = require('opencode.ui.output_window')
  local was_at_bottom = output_window.viewport_at_bottom

  M._hidden = true
  M._toggling = true

  pcall(vim.api.nvim_win_close, windows.input_win, false)
  windows.input_win = nil

  vim.schedule(function()
    M._toggling = false
  end)

  output_window.focus_output(true)

  if was_at_bottom then
    vim.schedule(function()
      require('opencode.ui.renderer').scroll_to_bottom(true)
    end)
  end
end

---Show the input window by recreating it
function M._show()
  local windows = state.windows
  if not windows or not windows.input_buf or not windows.output_win then
    return
  end

  -- Don't recreate if already visible
  if windows.input_win and vim.api.nvim_win_is_valid(windows.input_win) then
    M._hidden = false
    return
  end

  local output_window = require('opencode.ui.output_window')
  local was_at_bottom = output_window.viewport_at_bottom

  local output_win = windows.output_win
  vim.api.nvim_set_current_win(output_win)

  local input_position = config.ui.input_position or 'bottom'
  vim.cmd((input_position == 'top' and 'aboveleft' or 'belowright') .. ' split')
  local input_win = vim.api.nvim_get_current_win()

  vim.api.nvim_win_set_buf(input_win, windows.input_buf)
  windows.input_win = input_win

  -- Re-apply window settings
  M.setup(windows)

  M._hidden = false

  -- Focus the input window
  M.focus_input()

  if was_at_bottom then
    vim.schedule(function()
      require('opencode.ui.renderer').scroll_to_bottom(true)
    end)
  end
end

---Check if the input window is currently hidden
---@return boolean
function M.is_hidden()
  return M._hidden
end

return M
