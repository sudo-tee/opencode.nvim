local state = require('opencode.state')
local icons = require('opencode.ui.icons')
local Dialog = require('opencode.ui.dialog')
local Promise = require('opencode.promise')

local config = require('opencode.config')

local M = {}

M._current_question = nil
M._current_question_index = 1
M._collected_answers = {}
M._answering = false
M._dialog = nil

---@param question_request OpencodeQuestionRequest|nil
---@return boolean
function M.matches_active_question(question_request)
  return question_request ~= nil
    and M._current_question ~= nil
    and question_request.id ~= nil
    and M._current_question.id == question_request.id
end

---@param question_request OpencodeQuestionRequest|nil
---@return boolean
function M.belongs_to_active_session(question_request)
  if not question_request then
    return false
  end

  local active_session = state.active_session
  if active_session and active_session.id and question_request.sessionID == active_session.id then
    return true
  end

  local tool = question_request.tool
  local tool_message_id = tool and tool.messageID
  if tool_message_id and state.messages then
    for _, message in ipairs(state.messages) do
      if message.info and message.info.id == tool_message_id then
        return true
      end
    end
  end

  if question_request.sessionID and question_request.sessionID ~= '' then
    local render_state = require('opencode.ui.renderer.ctx').render_state
    return render_state:get_task_part_by_child_session(question_request.sessionID) ~= nil
  end

  return false
end

---@param question_request OpencodeQuestionRequest|nil
---@return boolean
local function has_tool_identifiers(question_request)
  local tool = question_request and question_request.tool
  return tool ~= nil and ((tool.callID and tool.callID ~= '') or (tool.messageID and tool.messageID ~= ''))
end

---@param part OpencodeMessagePart|nil
---@param question_request OpencodeQuestionRequest|nil
---@return boolean
local function question_part_matches_request(part, question_request)
  if not part or part.tool ~= 'question' or not question_request then
    return false
  end

  local tool = question_request.tool
  if not tool then
    return false
  end

  if tool.callID and tool.callID ~= '' and part.callID ~= tool.callID then
    return false
  end

  if tool.messageID and tool.messageID ~= '' and part.messageID ~= tool.messageID then
    return false
  end

  return true
end

---@param parts OpencodeMessagePart[]|nil
---@param question_request OpencodeQuestionRequest|nil
---@return OpencodeMessagePart|nil
local function find_matching_question_part(parts, question_request)
  for _, part in ipairs(parts or {}) do
    if question_part_matches_request(part, question_request) then
      return part
    end
  end
end

---@param question_request OpencodeQuestionRequest|nil
---@return OpencodeMessagePart|nil
local function get_question_part(question_request)
  if not has_tool_identifiers(question_request) then
    return nil
  end

  local tool = question_request.tool
  local tool_message_id = tool and tool.messageID

  if tool_message_id and state.messages then
    for _, message in ipairs(state.messages) do
      if message.info and message.info.id == tool_message_id then
        local part = find_matching_question_part(message.parts, question_request)
        if part then
          return part
        end
      end
    end
  end

  if question_request and question_request.sessionID and question_request.sessionID ~= '' then
    local render_state = require('opencode.ui.renderer.ctx').render_state
    return find_matching_question_part(render_state:get_child_session_parts(question_request.sessionID), question_request)
  end
end

---@param question_request OpencodeQuestionRequest|nil
---@return boolean
local function is_resolved_question_request(question_request)
  local part = get_question_part(question_request)
  if not part or not part.state then
    return false
  end

  local metadata = part.state.metadata
  if metadata and metadata.answers and #metadata.answers > 0 then
    return true
  end

  local status = part.state.status
  return status ~= nil and status ~= '' and status ~= 'pending' and status ~= 'running'
end

---Request the renderer to show the current question display.
local function render_question()
  require('opencode.ui.renderer.events').render_question_display()
end

---Request the renderer to remove the current question display.
local function clear_question()
  require('opencode.ui.renderer.events').clear_question_display()
end

---@param question_request OpencodeQuestionRequest
function M.show_question(question_request)
  if not question_request or not question_request.questions or #question_request.questions == 0 then
    return
  end

  if is_resolved_question_request(question_request) then
    return
  end

  M._current_question = question_request
  M._current_question_index = 1
  M._collected_answers = {}

  if config.ui.questions and config.ui.questions.use_vim_ui_select then
    M._show_question_with_vim_ui_select()
  else
    M._setup_dialog()
    render_question()
  end
end

---@param session_id string|nil
function M.restore_pending_question(session_id)
  if not state.api_client or not session_id or session_id == '' then
    return Promise.new():resolve(nil)
  end

  if M.has_question() and M.belongs_to_active_session(M._current_question) then
    if not is_resolved_question_request(M._current_question) then
      return Promise.new():resolve(nil)
    end

    M.clear_question()
  end

  return state.api_client:list_questions()
    :and_then(function(requests)
      if not requests or type(requests) ~= 'table' then
        return
      end

      for _, request in ipairs(requests) do
        if request
          and request.questions
          and #request.questions > 0
          and M.belongs_to_active_session(request)
          and not is_resolved_question_request(request)
        then
          if M.matches_active_question(request) then
            return
          end

          M.show_question(request)
          return
        end
      end
    end)
    :catch(function(err)
      vim.schedule(function()
        vim.notify('Failed to restore pending question: ' .. vim.inspect(err), vim.log.levels.WARN)
      end)
    end)
end

---Reset the current question state and remove any dialog UI.
function M.clear_question()
  M._clear_dialog()
  M._current_question = nil
  M._current_question_index = 1
  M._collected_answers = {}
  M._answering = false
  render_question()
end

---@return OpencodeQuestionInfo|nil
function M.get_current_question_info()
  if not M._current_question or not M._current_question.questions then
    return nil
  end
  local questions = M._current_question.questions
  local idx = M._current_question_index
  return (idx > 0 and idx <= #questions) and questions[idx] or nil
end

---@return boolean
function M.has_question()
  return M._current_question ~= nil and M.get_current_question_info() ~= nil
end

---@param answer_value string|string[]
local function answer_current_question(answer_value)
  local request = M._current_question
  if not request then
    return
  end

  table.insert(M._collected_answers, type(answer_value) == 'table' and answer_value or { answer_value })
  M._current_question_index = M._current_question_index + 1

  if M._current_question_index > #request.questions then
    M._send_reply(request.id, M._collected_answers)
    M.clear_question()
  else
    M._answering = false
    M._clear_dialog()
    M._setup_dialog()
  end
  render_question()

  -- Use schedule to ensure UI updates happen after all state changes
  vim.schedule(function()
    require('opencode.ui.renderer').scroll_to_bottom(true)
  end)
end

---@param options OpencodeQuestionOption[]
---@return integer|nil
local function find_other_option(options)
  for i, opt in ipairs(options) do
    if vim.startswith(opt.label:lower(), 'other') then
      return i
    end
  end
  return nil
end

---@param question_info OpencodeQuestionInfo
---@return integer
local function get_total_options(question_info)
  local has_other = find_other_option(question_info.options) ~= nil
  return has_other and #question_info.options or (#question_info.options + 1)
end

---@param option_index number
function M._answer_with_option(option_index)
  local question_info = M.get_current_question_info()
  if not question_info or not question_info.options then
    return
  end

  local other_index = find_other_option(question_info.options)
  local total_options = get_total_options(question_info)

  if option_index < 1 or option_index > total_options then
    vim.notify('Invalid option selected', vim.log.levels.WARN)
    return
  end

  if (not other_index and option_index == total_options) or (other_index and option_index == other_index) then
    M._answer_with_custom()
    return
  end

  answer_current_question(question_info.options[option_index].label)
end

---Prompt for a free-form answer to the active question.
function M._answer_with_custom()
  vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
    if input and input ~= '' then
      answer_current_question(input)
    elseif M._current_question.id then
      M._send_reject(M._current_question.id)
      M.clear_question()
      render_question()
    end
  end)
end

---@param options OpencodeQuestionOption[]
---@return OpencodeQuestionOption[]
local function add_other_if_missing(options)
  if find_other_option(options) ~= nil then
    return options
  end
  local result = vim.deepcopy(options)
  table.insert(result, { label = 'Other', description = 'Type your own answer' })
  return result
end

---@param output Output
function M.format_display(output)
  if not M.has_question() or M._answering then
    return
  end

  local question_info = M.get_current_question_info()
  if not question_info or not M._dialog then
    return
  end

  local icons = require('opencode.ui.icons')

  local progress = ''
  if M._current_question and #M._current_question.questions > 1 then
    progress = string.format(' (%d/%d)', M._current_question_index, #M._current_question.questions)
  end

  -- Prepare options
  local options_to_display = add_other_if_missing(question_info.options)
  local options = {}
  for i, option in ipairs(options_to_display) do
    table.insert(options, {
      label = option.label,
      description = option.description,
    })
  end

  -- Use dialog's format_dialog method
  M._dialog:format_dialog(output, {
    title = icons.get('question') .. ' Question' .. progress,
    title_hl = 'OpencodeQuestionTitle',
    border_hl = 'OpencodeQuestionBorder',
    content = vim.split(question_info.question, '\n'),
    options = options,
    unfocused_message = 'Focus Opencode window to answer question',
  })
end

---Create the in-buffer dialog used to answer the active question.
function M._setup_dialog()
  if not M.has_question() then
    return
  end

  M._clear_dialog()

  local question_info = M.get_current_question_info()
  if not question_info or not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf

  ---@return boolean
  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and M.has_question()
  end

  ---@param index integer
  local function on_select(index)
    if not check_focused() then
      return
    end
    M._answering = true
    render_question()
    M._clear_dialog()
    vim.defer_fn(function()
      M._answer_with_option(index)
    end, 100)
  end

  ---Reject the current question if the dialog is dismissed.
  local function on_dismiss()
    if not check_focused() then
      return
    end
    M._send_reject(M._current_question.id)
    M.clear_question()
    render_question()
  end

  ---Refresh the rendered question state after navigation changes.
  local function on_navigate()
    render_question()
  end

  ---@return integer
  local function get_option_count()
    local question_info = M.get_current_question_info()
    return question_info and get_total_options(question_info) or 0
  end

  M._dialog = Dialog.new({
    buffer = buf,
    on_select = on_select,
    on_dismiss = on_dismiss,
    on_navigate = on_navigate,
    get_option_count = get_option_count,
    check_focused = check_focused,
    namespace_prefix = 'opencode_question',
  })

  M._dialog:setup()
end

---Tear down the active question dialog, if any.
function M._clear_dialog()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
end

---Show question using vim.ui.select
function M._show_question_with_vim_ui_select()
  if not M.has_question() then
    return
  end

  local question_info = M.get_current_question_info()
  if not question_info or not question_info.options then
    return
  end

  local options_to_display = add_other_if_missing(question_info.options)
  local progress = ''
  if M._current_question and #M._current_question.questions > 1 then
    progress = string.format(' (%d/%d)', M._current_question_index, #M._current_question.questions)
  end

  local prompt = question_info.question .. progress
  local choices = {}
  for i, option in ipairs(options_to_display) do
    table.insert(choices, option.label)
  end

  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(item)
      return item
    end,
  }, function(choice)
    if not choice then
      -- User cancelled
      if M._current_question and M._current_question.id then
        M._send_reject(M._current_question.id)
      end
      M.clear_question()
      return
    end

    -- Find the selected option index
    local selected_index = nil
    for i, option in ipairs(options_to_display) do
      if option.label == choice then
        selected_index = i
        break
      end
    end

    if selected_index then
      M._answering = true
      M._answer_with_option(selected_index)
    end
  end)
end

---@param request_id string
---@param answers string[][]
function M._send_reply(request_id, answers)
  if state.api_client then
    state.api_client:reply_question(request_id, answers):catch(function(err)
      vim.notify('Failed to reply to question: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
  end
end

---@param request_id string
function M._send_reject(request_id)
  if state.api_client then
    state.api_client:reject_question(request_id):catch(function(err)
      vim.notify('Failed to reject question: ' .. vim.inspect(err), vim.log.levels.ERROR)
    end)
  end
end

return M
