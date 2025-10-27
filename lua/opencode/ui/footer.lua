local state = require('opencode.state')
local config = require('opencode.config')
local util = require('opencode.util')
local icons = require('opencode.ui.icons')
local output_window = require('opencode.ui.output_window')
local snapshot = require('opencode.snapshot')
local config_file = require('opencode.config_file')
local loading_animation = require('opencode.ui.loading_animation')

local M = {}

function M.render()
  local windows = state.windows
  if not output_window.mounted(windows) or not M.mounted(windows) then
    return
  end

  local segments = {}

  local append_to_footer = function(text)
    return text and text ~= '' and table.insert(segments, text)
  end

  if state.is_running() then
    local config_mod = require('opencode.config')
    local cancel_keymap = config_mod.get_key_for_function('input_window', 'stop') or '<C-c>'
    local legend = string.format(' %s to cancel', cancel_keymap)
    append_to_footer(legend)
  end

  if state.current_model then
    if config.ui.display_context_size then
      local provider, model = state.current_model:match('^(.-)/(.+)$')
      local model_info = config_file.get_model_info(provider, model)
      local limit = state.tokens_count and model_info and model_info.limit and model_info.limit.context or 0
      append_to_footer(util.format_number(state.tokens_count))
      append_to_footer(util.format_percentage(limit > 0 and state.tokens_count / limit))
    end
    if config.ui.display_cost then
      append_to_footer(util.format_cost(state.cost))
    end
  end
  local restore_points = snapshot.get_restore_points()
  if restore_points and #restore_points > 0 then
    local restore_point_text = string.format('%s %d', icons.get('restore_point'), #restore_points)
    append_to_footer(restore_point_text)
  end

  ---@diagnostic disable-next-line: need-check-nil
  local win_width = vim.api.nvim_win_get_width(windows.output_win)
  local footer_text = table.concat(segments, ' | ') .. ' '
  footer_text = string.rep(' ', win_width - #footer_text) .. footer_text

  M.set_content({ footer_text })
end

---@param windows OpencodeWindowState
function M._build_footer_win_config(windows)
  return {
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
  }
end

local function on_change(_, _, _)
  M.render()
end

local function on_job_count_changed(_, new, old)
  if new == 0 or old == 0 then
    M.render()
  end
end

function M.setup(windows)
  windows.footer_win = vim.api.nvim_open_win(windows.footer_buf, false, M._build_footer_win_config(windows))
  vim.api.nvim_set_option_value('winhl', 'Normal:OpenCodeHint', { win = windows.footer_win })

  -- for stats changes
  state.subscribe('current_model', on_change)
  -- to show C-c message
  state.subscribe('job_count', on_job_count_changed)
  state.subscribe('restore_points', on_change)

  loading_animation.setup()
end

function M.close()
  if state.windows then
    pcall(vim.api.nvim_win_close, state.windows.footer_win, true)
    pcall(vim.api.nvim_buf_delete, state.windows.footer_buf, { force = true })
  end

  state.unsubscribe('current_model', on_change)
  state.unsubscribe('job_count', on_job_count_changed)
  state.unsubscribe('restore_points', on_change)

  loading_animation.teardown()
end

function M.mounted(windows)
  windows = state.windows
  return windows
    and windows.footer_win
    and vim.api.nvim_win_is_valid(windows.footer_win)
    and vim.api.nvim_win_is_valid(windows.output_win)
end

function M.update_window(windows)
  if not M.mounted(windows) then
    return
  end

  vim.api.nvim_win_set_config(windows.footer_win, M._build_footer_win_config(windows))
  M.render()
end

---@return integer
function M.create_buf()
  local footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_footer', { buf = footer_buf })
  return footer_buf
end

function M.clear()
  local windows = state.windows
  if not M.mounted() or not windows then
    return
  end

  local foot_ns_id = vim.api.nvim_create_namespace('opencode_footer')
  vim.api.nvim_buf_clear_namespace(windows.footer_buf, foot_ns_id, 0, -1)

  M.set_content({})
  --
  -- state.tokens_count = 0
  -- state.cost = 0
end

function M.set_content(lines)
  local windows = state.windows
  if not M.mounted() or not windows then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.footer_buf })
  vim.api.nvim_buf_set_lines(windows.footer_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.footer_buf })
end

return M
