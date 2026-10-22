local config = require('opencode.config')
local status = require('opencode.services.program_status')
local store = require('opencode.state.store')

local M = {}
local ESC = '\027'
local ST = ESC .. '\\'
local TITLE_BYTES = 192
local prefix = 'opencode.nvim-' .. vim.fn.getpid() .. '/'
local focused = true

---@param text string
---@return string
local function title(text)
  local clean = text:gsub('[%z\1-\31\127]', ' '):gsub('\194[\128-\159]', ' ')
  if #clean <= TITLE_BYTES then
    return clean
  end
  return clean:sub(1, TITLE_BYTES + vim.str_utf_start(clean, TITLE_BYTES + 1))
end

---@param sequence string
---@return string
local function wrap_tmux(sequence)
  return ESC .. 'Ptmux;' .. sequence:gsub(ESC, ESC .. ESC) .. ST
end

---@param record OpencodeProgramStatusRecord
---@return string
function M.encode(record)
  local fields = {}
  local function add(key, value)
    if value then
      fields[#fields + 1] = key .. '=' .. value
    end
  end

  add('state', record.state)
  add('id', prefix .. record.id)
  add('app', 'opencode.nvim')
  add('kind', record.kind)
  add('title', record.title and vim.base64.encode(title(record.title)))

  local sequence = ESC .. ']7501;' .. table.concat(fields, ':') .. ST
  return config.program_status.tmux and wrap_tmux(sequence) or sequence
end

---@param record OpencodeProgramStatusRecord
local function send(record)
  local sequence = M.encode(record)
  if vim.fn.has('nvim-0.12') == 1 then
    vim.api.nvim_ui_send(sequence)
  elseif #vim.api.nvim_list_uis() > 0 and vim.fn.has('ttyout') == 1 then
    -- Before 0.12 the built-in TUI shares stderr with the editor process.
    vim.api.nvim_chan_send(vim.v.stderr, sequence)
  end
end

---@param id string
---@return boolean
local function is_seen(id)
  local windows = store.get('windows')
  local output = windows and windows.output_win
  return focused
    and store.get('active_session_tab') == id
    and store.get('is_opencode_focused')
    and output ~= nil
    and vim.api.nvim_win_is_valid(output)
    and vim.api.nvim_win_get_tabpage(output) == vim.api.nvim_get_current_tabpage()
end

function M.setup()
  status.stop()
  local group = vim.api.nvim_create_augroup('OpencodeProgramStatus', { clear = true })
  if not config.program_status.enabled then
    return
  end
  status.start(send, is_seen)
  vim.api.nvim_create_autocmd({ 'FocusGained', 'FocusLost' }, {
    group = group,
    callback = function(event)
      focused = event.event == 'FocusGained'
      status.refresh()
    end,
  })
  vim.api.nvim_create_autocmd('VimLeavePre', { group = group, callback = status.stop })
end

return M
