local Timer = require('opencode.ui.timer')
local M = {}

local state = require('opencode.state')
local formatter = require('opencode.ui.session_formatter')
local loading_animation = require('opencode.ui.loading_animation')

local LABELS = {
  GENERATING_RESPONSE = 'Thinking...',
}

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

  if state.opencode_run_job then
    M._cache.check_counter = (M._cache.check_counter + 1) % 3
    if M._cache.check_counter == 0 then
      local has_file_changed = stat.mtime.sec > M._cache.last_modified
      if has_file_changed then
        M._cache.last_modified = stat.mtime.sec
        return true
      end
    end
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

function M._start_refresh_timer(windows)
  M._stop_refresh_timer()

  M._refresh_timer = Timer.new({
    interval = 300,
    on_tick = function()
      if state.opencode_run_job then
        if M._should_refresh_content() then
          M.render(windows, true)
        end
        return true
      else
        M._stop_refresh_timer()
        M.render(windows, true)
        return false
      end
    end,
    repeat_timer = true,
  })
  M._refresh_timer:start()
end

function M._stop_refresh_timer()
  if M._refresh_timer then
    M._refresh_timer:stop()
    M._refresh_timer = nil
  end
end

M.render = vim.schedule_wrap(function(windows, force_refresh)
  if not windows or not windows.output_buf then
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

    M.write_output(windows, output_lines)
    require('opencode.ui.footer').render(windows)

    M.handle_auto_scroll(windows)
  end
  render()
  require('opencode.ui.mention').highlight_all_mentions(windows.output_buf)
  require('opencode.ui.contextual_actions').setup_contextual_actions()
  require('opencode.ui.topbar').render()

  vim.schedule(function()
    M.render_markdown()
  end)
end)

function M.stop()
  loading_animation.stop()

  M._stop_refresh_timer()

  M._cache = {
    last_modified = 0,
    output_lines = nil,
    session_path = nil,
    check_counter = 0,
    last_output = 0,
  }
end

function M.handle_loading(windows)
  if state.opencode_run_job then
    M._start_refresh_timer(windows)
    loading_animation.start(windows)
  else
    loading_animation.stop()
    M._stop_refresh_timer()
  end
end

function M.write_output(windows, output_lines)
  if not windows or not windows.output_buf then
    return
  end

  vim.api.nvim_set_option_value('modifiable', true, { buf = windows.output_buf })
  vim.api.nvim_buf_set_lines(windows.output_buf, 0, -1, false, output_lines)
  vim.api.nvim_set_option_value('modifiable', false, { buf = windows.output_buf })

  M.apply_output_extmarks(windows)
end

function M.apply_output_extmarks(windows)
  if state.display_route then
    return
  end

  local extmarks = formatter.output:get_extmarks()
  local ns_id = vim.api.nvim_create_namespace('opencode_output')
  vim.api.nvim_buf_clear_namespace(windows.output_buf, ns_id, 0, -1)

  for line_num, marks in pairs(extmarks) do
    for _, mark in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(windows.output_buf, ns_id, line_num - 1, 0, mark)
    end
  end
end

function M.handle_auto_scroll(windows)
  local line_count = vim.api.nvim_buf_line_count(windows.output_buf)
  local botline = vim.fn.line('w$', windows.output_win)

  local prev_line_count = vim.b[windows.output_buf].prev_line_count or 0
  vim.b[windows.output_buf].prev_line_count = line_count

  local was_at_bottom = (botline >= prev_line_count) or prev_line_count == 0

  if was_at_bottom then
    require('opencode.ui.ui').scroll_to_bottom()
  end
end

return M
