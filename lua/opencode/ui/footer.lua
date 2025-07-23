local state = require('opencode.state')
local M = {}

local function format_context_size(n)
  if not n or n <= 0 then
    return nil
  end

  if n >= 1e6 then
    return string.format('%.1fM', n / 1e6)
  elseif n >= 1e3 then
    return string.format('%.1fK', n / 1e3)
  else
    return tostring(n)
  end
end

local function format_percentage(n)
  return n and n > 0 and string.format('%.1f%%', n * 100) or nil
end

local function format_cost(c)
  return c and c > 0 and string.format('$%.2f', c) or nil
end

function M.render(windows)
  if not windows or not windows.output_win or not windows.footer_buf then
    return
  end

  local models = require('opencode.models')
  local segments = {}

  local append_to_footer = function(text)
    return text and text ~= '' and table.insert(segments, text)
  end

  if state.current_model then
    local provider, model = state.current_model:match('^(.-)/(.+)$')
    local model_info = models.get(provider, model)
    local limit = state.tokens_count and model_info and model_info.limit and model_info.limit.context or 0
    append_to_footer(format_context_size(state.tokens_count))
    append_to_footer(format_percentage(limit > 0 and state.tokens_count / limit))
    append_to_footer(format_cost(state.cost))
  end

  local win_width = vim.api.nvim_win_get_width(windows.output_win)
  local footer_text = table.concat(segments, ' | ') .. ' '
  footer_text = string.rep(' ', win_width - #footer_text) .. footer_text

  M.set_content({ footer_text })

  if state.was_interrupted then
    local ns_id = vim.api.nvim_create_namespace('opencode_footer')
    vim.api.nvim_buf_clear_namespace(windows.footer_buf, ns_id, 0, -1)
    vim.api.nvim_buf_set_extmark(windows.footer_buf, ns_id, 0, 0, {
      virt_text = { { 'Session was interrupted', 'Error' } },
      virt_text_pos = 'overlay',
      hl_mode = 'replace',
    })
  end
end

---@param windows OpencodeWindowState
function M.create_window(windows)
  windows.footer_win = vim.api.nvim_open_win(windows.footer_buf, false, {
    relative = 'win',
    win = windows.output_win,
    anchor = 'SW',
    width = vim.api.nvim_win_get_width(windows.output_win),
    height = 1,
    row = vim.api.nvim_win_get_height(windows.output_win) - 1,
    col = 0,
    focusable = false,
    style = 'minimal',
    border = 'none',
    zindex = 50,
  })
  vim.api.nvim_win_set_option(windows.footer_win, 'winhl', 'Normal:Comment')
end

function M.update_window(windows)
  if not windows or not windows.footer_win or not windows.footer_buf then
    return
  end

  local win_width = vim.api.nvim_win_get_width(windows.output_win)
  vim.api.nvim_win_set_config(windows.footer_win, {
    width = win_width,
    col = 0,
  })

  M.render(windows)
end

---@return integer
function M.create_buf()
  local footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_footer', { buf = footer_buf })
  return footer_buf
end

function M.clear_footer()
  local windows = state.windows

  local ns_id = vim.api.nvim_create_namespace('loading_animation')
  vim.api.nvim_buf_clear_namespace(windows.footer_buf, ns_id, 0, -1)

  local foot_ns_id = vim.api.nvim_create_namespace('opencode_footer')
  vim.api.nvim_buf_clear_namespace(windows.footer_buf, foot_ns_id, 0, -1)

  M.set_content({})

  state.was_interrupted = false
  state.tokens_count = 0
  state.cost = 0
end

function M.set_content(lines)
  local windows = state.windows
  if not windows or not windows.footer_buf then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.footer_buf })
  vim.api.nvim_buf_set_lines(windows.footer_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.footer_buf })
end

function M.close()
  if not state.windows then
    return
  end

  pcall(vim.api.nvim_win_close, state.windows.footer_win, true)
  pcall(vim.api.nvim_buf_delete, state.windows.footer_buf, { force = true })
end

return M
