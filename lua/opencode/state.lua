local config = require('opencode.config').get()
local M = {}
---@class OpencodeWindowState
---@field input_win number|nil
---@field output_win number|nil
---@field footer_win number|nil
---@field footer_buf number|nil
---@field input_buf number|nil
---@field output_buf number|nil

-- ui
---@type OpencodeWindowState
M.windows = nil
M.input_content = {}
M.last_focused_opencode_window = nil
M.last_input_window_position = nil
M.last_output_window_position = nil
M.last_code_win_before_opencode = nil
M.display_route = nil
M.current_mode = config.default_mode
M.was_interrupted = false
M.last_output = 0

-- context
M.last_sent_context = nil

-- session
M.active_session = nil
M.new_session_name = nil
M.current_model = nil

-- messages
M.messages = nil
M.current_message = nil
M.cost = 0
M.tokens_count = 0

-- job
M.opencode_run_job = nil

return M
