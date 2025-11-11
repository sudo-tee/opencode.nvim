local state = require('opencode.state')
local config = require('opencode.config')
local icons = require('opencode.ui.icons')
local output_window = require('opencode.ui.output_window')
local snapshot = require('opencode.snapshot')
local loading_animation = require('opencode.ui.loading_animation')

local M = {}

local function get_mode_highlight()
  local mode = (state.current_mode or ''):lower()
  local highlights = {
    build = 'OpencodeAgentBuild',
    plan = 'OpencodeAgentPlan',
  }
  return highlights[mode] or 'OpencodeAgentCustom'
end

local function build_left_segments()
  local segments = {}
  if not state.is_running() and state.current_model then
    table.insert(segments, state.current_model)
  end
  return segments
end

local function build_right_segments()
  local segments = {}

  if state.is_running() then
    local cancel_keymap = config.get_key_for_function('input_window', 'stop') or '<C-c>'
    table.insert(segments, string.format(' %s to cancel', cancel_keymap))
  end

  local restore_points = snapshot.get_restore_points()
  if restore_points and #restore_points > 0 then
    table.insert(segments, string.format('%s %d', icons.get('restore_point'), #restore_points))
  end

  if state.current_mode then
    table.insert(segments, string.format(' %s ', state.current_mode:upper()))
  end

  return segments
end

local function build_footer_text(left_text, right_text, win_width)
  local left_len = #left_text > 0 and #left_text + 1 or 0
  local right_len = #right_text > 0 and #right_text + 1 or 0
  local padding = math.max(0, win_width - left_len - right_len)

  local parts = {}
  if #left_text > 0 then
    table.insert(parts, left_text)
  end
  table.insert(parts, string.rep(' ', padding))
  if #right_text > 0 then
    table.insert(parts, right_text)
  end

  return table.concat(parts, ' ')
end

local function create_mode_highlight(left_len, right_text, padding)
  if not state.current_mode then
    return {}
  end

  local mode_text = string.format(' %s ', state.current_mode:upper())
  local mode_start = left_len + padding + (#right_text > 0 and 1 or 0)

  return {
    {
      group = get_mode_highlight(),
      start_col = mode_start + #right_text - #mode_text,
      end_col = mode_start + #right_text,
    },
  }
end

function M.render()
  if not output_window.mounted() or not M.mounted() then
    return
  end
  ---@cast state.windows OpencodeWindowState

  local left_text = table.concat(build_left_segments(), ' ')
  local right_text = table.concat(build_right_segments(), ' ')
  local win_width = vim.api.nvim_win_get_width(state.windows.output_win --[[@as integer]])

  local footer_text = build_footer_text(left_text, right_text, win_width)
  local highlights = create_mode_highlight(#left_text, right_text, win_width - #left_text - #right_text - 1)

  M.set_content({ footer_text }, highlights)
end

---@param output_win integer
function M._build_footer_win_config(output_win)
  return {
    relative = 'win',
    win = output_win,
    anchor = 'SW',
    width = vim.api.nvim_win_get_width(output_win),
    height = 1,
    row = vim.api.nvim_win_get_height(output_win) - 1,
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

---@param windows table Windows table to set up footer in
function M.setup(windows)
  if not windows.output_win then
    return false
  end

  windows.footer_win = vim.api.nvim_open_win(windows.footer_buf, false, M._build_footer_win_config(windows.output_win))
  vim.api.nvim_set_option_value('winhl', 'Normal:OpencodeHint', { win = windows.footer_win })

  -- for model changes
  state.subscribe('current_model', on_change)
  state.subscribe('current_mode', on_change)
  state.subscribe('active_session', on_change)
  -- to show C-c message
  state.subscribe('job_count', on_job_count_changed)
  state.subscribe('restore_points', on_change)

  vim.api.nvim_create_autocmd({ 'VimResized', 'WinResized' }, {
    callback = function()
      M.update_window(windows)
    end,
  })

  loading_animation.setup()
end

function M.close()
  local windows = state.windows
  if windows then
    ---@cast windows {footer_win: integer, footer_buf: integer}
    pcall(vim.api.nvim_win_close, windows.footer_win, true)
    pcall(vim.api.nvim_buf_delete, windows.footer_buf, { force = true })
  end

  state.unsubscribe('current_model', on_change)
  state.unsubscribe('current_mode', on_change)
  state.unsubscribe('active_session', on_change)
  state.unsubscribe('job_count', on_job_count_changed)
  state.unsubscribe('restore_points', on_change)

  loading_animation.teardown()
end

local function is_valid_state(windows)
  return windows and windows.footer_win and windows.output_win and windows.footer_buf
end

---@param windows? table Optional windows table, defaults to state.windows
---@return boolean # True if the footer is properly mounted and windows are valid
function M.mounted(windows)
  windows = windows or state.windows
  return windows
    and is_valid_state(windows)
    and vim.api.nvim_win_is_valid(windows.footer_win --[[@as integer]])
    and vim.api.nvim_win_is_valid(windows.output_win --[[@as integer]])
end

---@param windows table Windows table with footer_win and output_win
function M.update_window(windows)
  if not M.mounted(windows) then
    return
  end

  vim.api.nvim_win_set_config(
    windows.footer_win --[[@as integer]],
    M._build_footer_win_config(windows.output_win --[[@as integer]])
  )
  M.render()
end

---@return integer
function M.create_buf()
  local footer_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value('filetype', 'opencode_footer', { buf = footer_buf })
  return footer_buf
end

---@param lines string[] Content lines to set in footer
---@param highlights? table[] Optional highlight definitions
function M.set_content(lines, highlights)
  if not M.mounted() then
    return
  end
  ---@cast state.windows OpencodeWindowState

  local buf = state.windows.footer_buf --[[@as integer]]
  local ns_id = vim.api.nvim_create_namespace('opencode_footer')

  vim.api.nvim_set_option_value('modifiable', true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines or {})
  vim.api.nvim_buf_clear_namespace(buf, ns_id, 0, -1)

  if highlights and #lines > 0 then
    local line_length = #(lines[1] or '')
    for _, highlight in ipairs(highlights) do
      local start_col = math.max(0, math.min(highlight.start_col, line_length))
      local end_col = math.max(start_col, math.min(highlight.end_col, line_length))

      if start_col < end_col then
        vim.api.nvim_buf_set_extmark(buf, ns_id, 0, start_col, {
          end_col = end_col,
          hl_group = highlight.group,
        })
      end
    end
  end

  vim.api.nvim_set_option_value('modifiable', false, { buf = buf })
end

function M.clear()
  M.set_content({})
end

return M
