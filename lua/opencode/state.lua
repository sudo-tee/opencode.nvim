local M = {}

-- ui
M.windows = nil
M.input_content = {}
M.last_focused_opencode_window = nil
M.last_input_window_position = nil
M.last_output_window_position = nil
M.last_code_win_before_opencode = nil
M.slash_command = nil
-- context
M.last_sent_context = nil

-- session
M.active_session = nil
M.new_session_name = nil

-- job
M.opencode_run_job = nil

return M
