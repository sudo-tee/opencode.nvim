local M = {}

-- ui
M.windows = nil
M.input_content = {}
M.last_focused_opencode_window = nil
M.last_input_window_position = nil
M.last_output_window_position = nil
M.last_code_win_before_opencode = nil
M.display_route = nil
M.current_mode = require('opencode.config').get().default_mode
M.was_interrupted = false

-- context
M.last_sent_context = nil

-- session
M.active_session = nil
M.new_session_name = nil
M.current_model = nil

-- job
M.opencode_run_job = nil

return M
