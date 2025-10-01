local config = require('opencode.config').get()
local icons = require('opencode.ui.icons')

local M = {}

local state = {
  win = nil,
  buf = nil,
  callback = nil,
}

local function get_tool_icon(tool)
  if tool == 'bash' then
    return '💻'
  elseif tool == 'edit' then
    return '✏️'
  elseif tool == 'webfetch' then
    return '🌐'
  else
    return '🔒'
  end
end

local function get_tool_display_name(tool)
  if tool == 'bash' then
    return 'Bash Command'
  elseif tool == 'edit' then
    return 'File Edit'
  elseif tool == 'webfetch' then
    return 'Web Fetch'
  else
    return 'Permission Request'
  end
end

local function close_prompt()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.win = nil
  state.buf = nil
  state.callback = nil
end

local function respond(response)
  local cb = state.callback
  close_prompt()
  if cb then
    cb(response)
  end
end

local function setup_keymaps(bufnr)
  local opts = { noremap = true, silent = true, buffer = bufnr }

  vim.keymap.set('n', 'a', function()
    respond('allow')
  end, opts)
  vim.keymap.set('n', 'A', function()
    respond('allow')
  end, opts)

  vim.keymap.set('n', 'd', function()
    respond('deny')
  end, opts)
  vim.keymap.set('n', 'D', function()
    respond('deny')
  end, opts)

  vim.keymap.set('n', '<CR>', function()
    respond('allow')
  end, opts)

  vim.keymap.set('n', '<Esc>', function()
    respond('deny')
  end, opts)

  vim.keymap.set('n', 'q', function()
    respond('deny')
  end, opts)
end

function M.show(permission_request, callback)
  if state.win then
    close_prompt()
  end

  state.callback = callback

  local tool_icon = get_tool_icon(permission_request.tool)
  local tool_name = get_tool_display_name(permission_request.tool)

  local action_lines = vim.split(permission_request.action, '\n', { plain = true })

  local lines = {
    '',
    string.format('  %s %s', tool_icon, tool_name),
    '  ' .. string.rep('─', 40),
    '',
  }

  for _, line in ipairs(action_lines) do
    table.insert(lines, '  ' .. line)
  end

  table.insert(lines, '')
  table.insert(lines, '  Allow opencode to perform this action?')
  table.insert(lines, '')
  table.insert(lines, '  [A]llow  [D]eny  <CR> to allow  <Esc> to deny')
  table.insert(lines, '')

  local width = config.ui.permission_prompt.width or 60
  local height = #lines

  local editor_width = vim.o.columns
  local editor_height = vim.o.lines
  local row = math.floor((editor_height - height) / 2)
  local col = math.floor((editor_width - width) / 2)

  state.buf = vim.api.nvim_create_buf(false, true)

  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = state.buf })
  vim.api.nvim_set_option_value('buftype', 'nofile', { buf = state.buf })
  vim.api.nvim_set_option_value('swapfile', false, { buf = state.buf })

  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' Permission Request ',
    title_pos = 'center',
    zindex = 100,
  })

  vim.api.nvim_set_option_value('winblend', 0, { win = state.win })
  vim.api.nvim_set_option_value('winhighlight', 'Normal:Normal,FloatBorder:OpencodeBorder', { win = state.win })

  setup_keymaps(state.buf)

  vim.api.nvim_create_autocmd('WinClosed', {
    buffer = state.buf,
    once = true,
    callback = function()
      respond('deny')
    end,
  })
end

function M.close()
  close_prompt()
end

function M.is_open()
  return state.win ~= nil and vim.api.nvim_win_is_valid(state.win)
end

return M
