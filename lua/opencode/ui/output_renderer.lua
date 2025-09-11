local Timer = require('opencode.ui.timer')
local M = {}

local state = require('opencode.state')
local formatter = require('opencode.ui.session_formatter')
local loading_animation = require('opencode.ui.loading_animation')
local output_window = require('opencode.ui.output_window')

M._cache = {
  last_modified = 0,
  last_output = 0,
  output_lines = nil,
  session_path = nil,
  check_counter = 0,
}

function M.render_markdown()
  if vim.fn.exists(':RenderMarkdown') > 0 then
    vim.cmd(':RenderMarkdown')
  end
end

function M._should_refresh_content()
  if not state.active_session then
    return true
  end

  -- If any job is running, force refresh every 3rd tick
  if state.is_job_running() then
    M._cache.check_counter = (M._cache.check_counter + 1) % 3
    if M._cache.check_counter == 0 then
      return true
    end
  end

  if state.last_output and state.last_output > (M._cache.last_output or 0) then
    M._cache.last_output = state.last_output
    return true
  end

  local session_path = state.active_session.parts_path

  if session_path ~= M._cache.session_path then
    M._cache.session_path = session_path
    return true
  end

  if vim.fn.isdirectory(session_path) == 0 then
    return false
  end

  local stat = vim.loop.fs_stat(session_path)
  if not stat then
    return false
  end

  if stat.mtime.sec > M._cache.last_modified then
    M._cache.last_modified = stat.mtime.sec
    return true
  end

  return false
end

function M._read_session(force_refresh)
  if not state.active_session then
    return nil
  end

  if not force_refresh and not M._should_refresh_content() and M._cache.output_lines then
    return M._cache.output_lines
  end

  local output_lines = formatter.format_session(state.active_session)
  M._cache.output_lines = output_lines
  return output_lines
end

function M.start_refresh_timer(windows)
  if M._refresh_timer then
    return
  end
  M._refresh_timer = Timer.new({
    interval = 300,
    on_tick = function()
      if state.is_job_running() then
        if M._should_refresh_content() then
          M.render(windows, true)
        end
        return true
      else
        M.stop_refresh_timer()
        return false
      end
    end,
    on_stop = function()
      M.render(windows, true)
      vim.defer_fn(function()
        M.render(windows, true)
      end, 300)
    end,
    repeat_timer = true,
  })
  M._refresh_timer:start()
end

function M.stop_refresh_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer = nil
  end
end

M.render = vim.schedule_wrap(function(windows, force_refresh)
  if not output_window.mounted(windows) then
    return
  end

  local function render()
    if not state.active_session and not state.new_session_name then
      return
    end

    if not force_refresh and loading_animation.is_running() then
      return
    end

    local output_lines = M._read_session(force_refresh)
    local is_new_session = state.new_session_name ~= nil

    if not output_lines then
      if is_new_session then
        output_lines = { '' }
      else
        return
      end
    else
      state.new_session_name = nil
    end

    M.handle_loading(windows)

    local output_changed = M.write_output(windows, output_lines)

    if output_changed or force_refresh then
      vim.schedule(function()
        M.handle_auto_scroll(windows)
        M.render_markdown()
        require('opencode.ui.topbar').render()
      end)
    end
  end
  pcall(function()
    render()
    require('opencode.ui.mention').highlight_all_mentions(windows.output_buf)
    require('opencode.ui.contextual_actions').setup_contextual_actions()
    require('opencode.ui.footer').render(windows)
  end)
end)

function M.stop()
  loading_animation.stop()

  M.stop_refresh_timer()

  M._cache = {
    last_modified = 0,
    output_lines = nil,
    session_path = nil,
    check_counter = 0,
    last_output = 0,
  }
end

function M.handle_loading(windows)
  if state.is_job_running() then
    M.start_refresh_timer(windows)
    if not loading_animation.is_running() then
      loading_animation.start(windows)
    end
  else
    M.stop_refresh_timer()
    if loading_animation.is_running() then
      loading_animation.stop()
    end
  end
end

function M._last_n_lines_equal(prev_lines, current_lines, n)
  n = n or 5
  if #prev_lines ~= #current_lines then
    return false
  end
  local len = #prev_lines
  local start = math.max(1, len - n + 1)
  for i = start, len do
    if prev_lines[i] ~= current_lines[i] then
      return false
    end
  end
  return true
end

function M.write_output(windows, output_lines)
  if not output_window.mounted(windows) then
    return
  end

  local prev_lines = M._cache.prev_rendered_lines or {}
  local changed = not M._last_n_lines_equal(prev_lines, output_lines, 5)
  if changed then
    output_window.set_content(output_lines)
    M._cache.prev_rendered_lines = vim.deepcopy(output_lines)
    M.apply_output_extmarks(windows)
  end

  return changed
end

function M.apply_output_extmarks(windows)
  if state.display_route then
    return
  end

  local extmarks = formatter.output:get_extmarks()
  local ns_id = vim.api.nvim_create_namespace('opencode_output')
  pcall(vim.api.nvim_buf_clear_namespace, windows.output_buf, ns_id, 0, -1)

  for line_num, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      local actual_mark = mark
      if type(mark) == 'function' then
        actual_mark = mark()
      end
      pcall(vim.api.nvim_buf_set_extmark, windows.output_buf, ns_id, line_num - 1, 0, actual_mark)
    end
  end
end

function M.handle_auto_scroll(windows)
  local ok, line_count = pcall(vim.api.nvim_buf_line_count, windows.output_buf)
  if not ok then
    return
  end

  local botline = vim.fn.line('w$', windows.output_win)

  local prev_line_count = vim.b[windows.output_buf].prev_line_count or 0
  vim.b[windows.output_buf].prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  if was_at_bottom then
    require('opencode.ui.ui').scroll_to_bottom()
  end
end

return M
