local state = require('opencode.state')
local icons = require('opencode.ui.icons')
local Dialog = require('opencode.ui.dialog')
local Promise = require('opencode.promise')

local config = require('opencode.config')
local session_scope = require('opencode.ui.session_scope')

local M = {}

M._current_question = nil
M._current_question_index = 1
M._collected_answers = {}
M._multi_selections = {}
M._answering = false
M._dialog = nil
M._inline_input = nil
M._empty_confirm_armed = false

---@param index integer
---@return string[]|nil
local function get_answer_for_index(index)
  local answer = M._collected_answers[index]
  if type(answer) ~= 'table' then
    return nil
  end
  return answer
end

---@return boolean
local function has_all_answers()
  local request = M._current_question
  local questions = request and request.questions or {}
  if #questions == 0 then
    return false
  end

  for i = 1, #questions do
    if not get_answer_for_index(i) then
      return false
    end
  end

  return true
end

---@return integer|nil
local function get_next_unanswered_question_index()
  local request = M._current_question
  local questions = request and request.questions or {}
  if #questions == 0 then
    return nil
  end

  for i = 1, #questions do
    if not get_answer_for_index(i) then
      return i
    end
  end
end

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
function M.uses_vim_ui_select(question_request)
  if
    not config.ui.questions
    or not config.ui.questions.use_vim_ui_select
    or not question_request
    or not question_request.questions
    or #question_request.questions == 0
  then
    return false
  end

  for _, question in ipairs(question_request.questions) do
    if question.multiple == true then
      return false
    end
  end

  return true
end

---@param request_id string
---@param question_index integer
---@return boolean
local function is_active_question(request_id, question_index)
  return M._current_question ~= nil
    and M._current_question.id == request_id
    and M._current_question_index == question_index
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
    return find_matching_question_part(
      render_state:get_child_session_parts(question_request.sessionID),
      question_request
    )
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

---@param question_request OpencodeQuestionRequest
function M.show_question(question_request)
  if not question_request or not question_request.questions or #question_request.questions == 0 then
    return
  end

  if is_resolved_question_request(question_request) then
    return
  end

  M._clear_inline_input()
  M._clear_dialog()
  M._current_question = question_request
  M._collected_answers = {}
  M._multi_selections = {}
  M._other_input_drafts = {}
  M._current_question_index = 1
  M._answering = false
  M._empty_confirm_armed = false

  if M.uses_vim_ui_select(question_request) then
    M._show_question_with_vim_ui_select()
  else
    M._setup_dialog()
  end
  render_question()
end

---@param session_id string|nil
function M.restore_pending_question(session_id)
  if not state.api_client or not session_id or session_id == '' then
    return Promise.new():resolve(nil)
  end

  if M.has_question() and session_scope.belongs_to_active_session(M._current_question) then
    if not is_resolved_question_request(M._current_question) then
      return Promise.new():resolve(nil)
    end

    M.clear_question()
  end

  return state.api_client
    :list_questions()
    :and_then(function(requests)
      if not requests or type(requests) ~= 'table' then
        return
      end

      for _, request in ipairs(requests) do
        if
          request
          and request.questions
          and #request.questions > 0
          and session_scope.belongs_to_active_session(request)
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
  M._clear_inline_input()
  M._clear_dialog()
  M._current_question = nil
  M._current_question_index = 1
  M._collected_answers = {}
  M._multi_selections = {}
  M._other_input_drafts = {}
  M._answering = false
  M._empty_confirm_armed = false
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
---@param request_id string
---@param question_index integer
local function answer_current_question(answer_value, request_id, question_index)
  if not is_active_question(request_id, question_index) then
    return
  end

  local request = M._current_question
  if not request then
    return
  end

  M._collected_answers[M._current_question_index] = type(answer_value) == 'table' and answer_value or { answer_value }

  if has_all_answers() then
    M._send_reply(request.id, M._collected_answers)
    M.clear_question()
  else
    M._current_question_index = get_next_unanswered_question_index() or M._current_question_index
    M._answering = false
    M._clear_dialog()
    if M.uses_vim_ui_select(request) then
      M._show_question_with_vim_ui_select()
    else
      M._setup_dialog()
    end
  end
  render_question()

  -- Use schedule to ensure UI updates happen after all state changes
  vim.schedule(function()
    require('opencode.ui.renderer').scroll_to_bottom(true)
  end)
end

---@param question_info OpencodeQuestionInfo
---@return integer|nil
local function get_custom_option_index(question_info)
  return question_info.custom ~= false and #question_info.options + 1 or nil
end

---@param question_info OpencodeQuestionInfo
---@return integer
local function get_choice_count(question_info)
  return #question_info.options + (get_custom_option_index(question_info) and 1 or 0)
end

---@param question_info OpencodeQuestionInfo
---@return integer|nil
local function get_confirm_option_index(question_info)
  return question_info.multiple == true and get_choice_count(question_info) + 1 or nil
end

---@param question_info OpencodeQuestionInfo
---@return integer
local function get_total_options(question_info)
  return get_choice_count(question_info) + (get_confirm_option_index(question_info) and 1 or 0)
end

---@param option_index number
---@param request_id? string
---@param question_index? integer
function M._answer_with_option(option_index, request_id, question_index)
  local request = M._current_question
  if not request then
    return
  end

  local reopen_backend = request_id ~= nil and question_index ~= nil
  request_id = request_id or request.id
  question_index = question_index or M._current_question_index
  if not is_active_question(request_id, question_index) then
    return
  end

  local question_info = M.get_current_question_info()
  if not question_info or not question_info.options then
    return
  end

  local custom_option_index = get_custom_option_index(question_info)
  local total_options = get_choice_count(question_info)

  if option_index < 1 or option_index > total_options then
    vim.notify('Invalid option selected', vim.log.levels.WARN)
    return
  end

  if option_index == custom_option_index then
    M._answer_with_custom(request_id, question_index, reopen_backend)
    return
  end

  if question_info.multiple then
    M._toggle_multi_selection(option_index)
    render_question()
    return
  end

  answer_current_question(question_info.options[option_index].label, request_id, question_index)
end

---Toggle a multi-select option on/off
---@param option_index integer
function M._toggle_multi_selection(option_index)
  local question_info = M.get_current_question_info()
  if not question_info then
    return
  end

  local idx = M._current_question_index
  M._empty_confirm_armed = false
  M._multi_selections[idx] = M._multi_selections[idx] or {}

  if M._multi_selections[idx][option_index] then
    M._multi_selections[idx][option_index] = nil
  else
    M._multi_selections[idx][option_index] = true
  end
end

---Submit all selected multi-select answers for the current question
---@param request_id string
---@param question_index integer
function M._submit_multi_answers(request_id, question_index)
  if not is_active_question(request_id, question_index) then
    return
  end

  local request = M._current_question
  local question_info = M.get_current_question_info()
  if not request or not question_info then
    return
  end

  local selections = M._multi_selections[question_index] or {}
  local labels = {}

  for option_index = 1, #question_info.options do
    if selections[option_index] then
      table.insert(labels, question_info.options[option_index].label)
    end
  end

  if selections.custom_answer then
    table.insert(labels, selections.custom_answer)
  end

  if #labels == 0 and not M._empty_confirm_armed then
    M._empty_confirm_armed = true
    render_question()
    return
  end

  M._empty_confirm_armed = false
  M._answering = true
  render_question()

  vim.defer_fn(function()
    answer_current_question(labels, request_id, question_index)
  end, 100)
end

---@param request_id string
---@param question_index integer
---@param option_index integer|nil
---@param on_submit fun(text: string)
---@return boolean
local function open_inline_other_input(request_id, question_index, option_index, on_submit)
  if config.ui.questions.inline_other_input == false or not option_index then
    return false
  end

  local pos = M._dialog and M._dialog:get_option_position(option_index)
  local part_data = require('opencode.ui.renderer.ctx').render_state:get_part('question-display-part')
  if not (pos and part_data and part_data.line_start and state.windows and state.windows.output_win) then
    return false
  end

  M._clear_inline_input()
  local handle
  handle = require('opencode.ui.inline_input').open({
    win = state.windows.output_win,
    row = part_data.line_start + pos.line,
    col = pos.col,
    title = 'Type your answer',
    initial_text = M._other_input_drafts[question_index],
    on_submit = function(text)
      if M._inline_input == handle then
        M._inline_input = nil
      end
      M._other_input_drafts[question_index] = nil
      if is_active_question(request_id, question_index) then
        on_submit(text)
      end
    end,
    on_cancel = function()
      if M._inline_input == handle then
        M._inline_input = nil
      end
      if is_active_question(request_id, question_index) then
        render_question()
      end
    end,
    on_leave = function(text)
      M._other_input_drafts[question_index] = text
    end,
  })
  M._inline_input = handle
  return true
end

---Open inline input for multi-select "Other" custom answer
---@param request_id string
---@param question_index integer
function M._open_multi_other_input(request_id, question_index)
  if not is_active_question(request_id, question_index) then
    return
  end

  local question_info = M.get_current_question_info()
  if not question_info then
    return
  end

  M._empty_confirm_armed = false

  if
    open_inline_other_input(request_id, question_index, get_custom_option_index(question_info), function(text)
      M._multi_selections[question_index] = M._multi_selections[question_index] or {}
      M._multi_selections[question_index].custom_answer = text
      render_question()
    end)
  then
    return
  end

  vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
    if not is_active_question(request_id, question_index) then
      return
    end
    if input and input ~= '' then
      M._multi_selections[question_index] = M._multi_selections[question_index] or {}
      M._multi_selections[question_index].custom_answer = input
    end
    render_question()
  end)
end

---Prompt for a free-form answer to the active question.
---@param request_id? string
---@param question_index? integer
---@param reopen_backend? boolean
function M._answer_with_custom(request_id, question_index, reopen_backend)
  local request = M._current_question
  if not request then
    return
  end

  request_id = request_id or request.id
  question_index = question_index or M._current_question_index
  local question_info = M.get_current_question_info()
  if not question_info or question_info.custom == false then
    return
  end

  if question_info.multiple then
    M._open_multi_other_input(request_id, question_index)
    return
  end

  vim.ui.input({ prompt = 'Enter your response: ' }, function(input)
    if not is_active_question(request_id, question_index) then
      return
    end
    if input and input ~= '' then
      answer_current_question(input, request_id, question_index)
    else
      if reopen_backend then
        M._answering = false
        if M.uses_vim_ui_select(request) then
          M._show_question_with_vim_ui_select()
        else
          M._setup_dialog()
        end
      end
      render_question()
    end
  end)
end

---@param question_info OpencodeQuestionInfo
---@return OpencodeQuestionOption[]
local function get_display_options(question_info)
  local result = vim.deepcopy(question_info.options)
  if get_custom_option_index(question_info) then
    table.insert(result, { label = 'Other', description = 'Type your own answer' })
  end
  if get_confirm_option_index(question_info) then
    table.insert(result, { label = 'Confirm', description = 'Submit selected answers', confirm = true })
  end
  return result
end

---@param output Output
local function format_question_tabs(output)
  local request = M._current_question
  if not request or #request.questions <= 1 then
    return
  end

  local line = ''
  local segments = {}

  for i, question in ipairs(request.questions) do
    local label = question.header ~= '' and question.header or ('Q' .. i)
    local is_active = i == M._current_question_index
    local is_done = get_answer_for_index(i) ~= nil
    local marker = is_done and icons.get('completed') or ' '
    local segment = string.format(' %d [%s] %s ', i, label, marker)

    if #line > 0 then
      line = line .. ' '
    end

    local start_col = #line
    line = line .. segment
    table.insert(segments, {
      start_col = start_col,
      end_col = #line,
      hl_group = is_active and 'OpencodeQuestionTabActive'
        or (is_done and 'OpencodeQuestionTabDone' or 'OpencodeQuestionTabPending'),
    })
  end

  local line_idx = output:add_line(line)
  for _, segment in ipairs(segments) do
    output:add_extmark(line_idx - 1, {
      start_col = segment.start_col,
      end_col = segment.end_col,
      hl_group = segment.hl_group,
    } --[[@as OutputExtmark]])
  end

  output:add_line('')
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

  local is_multiple = question_info.multiple == true

  local progress = ''
  if M._current_question and #M._current_question.questions > 1 then
    progress = string.format(' (%d/%d)', M._current_question_index, #M._current_question.questions)
  end

  format_question_tabs(output)

  -- Prepare options
  local options_to_display = get_display_options(question_info)
  local selections = M._multi_selections[M._current_question_index] or {}
  local custom_option_index = get_custom_option_index(question_info)
  local options = {}
  for i, option in ipairs(options_to_display) do
    local desc = option.description
    local label = option.label
    if is_multiple and custom_option_index == i then
      desc = selections.custom_answer or desc
    elseif option.confirm and M._empty_confirm_armed then
      label = 'Confirm empty answer'
      desc = 'Press Enter again to submit no selections'
    end
    table.insert(options, {
      label = label,
      description = desc,
      checked = not option.confirm
        and (is_multiple and custom_option_index == i and selections.custom_answer ~= nil or selections[i] == true),
      confirm = option.confirm,
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

---@param index integer
---@return boolean
local function handle_other_option_inline(index, request_id, question_index)
  local question_info = M.get_current_question_info()
  local custom_option_index = question_info and get_custom_option_index(question_info)

  if index ~= custom_option_index then
    return false
  end

  return open_inline_other_input(request_id, question_index, index, function(text)
    answer_current_question(text, request_id, question_index)
  end)
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

  local request_id = M._current_question.id
  local question_index = M._current_question_index
  local is_multiple = question_info.multiple == true
  local buf = state.windows.output_buf

  ---@return boolean
  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and not M._answering and is_active_question(request_id, question_index)
  end

  ---@param index integer
  local function on_select(index)
    if not check_focused() then
      return
    end

    if is_multiple then
      if index == get_confirm_option_index(question_info) then
        M._submit_multi_answers(request_id, question_index)
        return
      end
      M._empty_confirm_armed = false
      if index == get_custom_option_index(question_info) then
        local idx = M._current_question_index
        local selections = M._multi_selections[idx] or {}
        if selections.custom_answer then
          selections.custom_answer = nil
          render_question()
        else
          M._open_multi_other_input(request_id, question_index)
        end
        return
      end
      M._toggle_multi_selection(index)
      render_question()
      return
    end

    if handle_other_option_inline(index, request_id, question_index) then
      return
    end

    M._answering = true
    render_question()
    vim.defer_fn(function()
      M._answer_with_option(index, request_id, question_index)
    end, 100)
  end

  ---Reject the current question if the dialog is dismissed.
  local function on_dismiss()
    if not check_focused() then
      return
    end
    M._send_reject(request_id)
    M.clear_question()
    render_question()
  end

  ---Refresh the rendered question state after navigation changes.
  local function on_navigate()
    M._empty_confirm_armed = false
    render_question()
  end

  ---@param index integer
  local function on_navigate_group(index)
    M._empty_confirm_armed = false
    M._current_question_index = index
    M._setup_dialog()
    render_question()
  end

  local question_count = #M._current_question.questions

  ---@return integer
  local function get_option_count()
    return get_total_options(question_info)
  end

  M._dialog = Dialog.new({
    buffer = buf,
    on_select = on_select,
    on_dismiss = on_dismiss,
    on_navigate = on_navigate,
    on_navigate_group = on_navigate_group,
    get_option_count = get_option_count,
    get_shortcut_count = function()
      return get_choice_count(question_info)
    end,
    get_group_count = function()
      return question_count
    end,
    check_focused = check_focused,
    is_multiple = is_multiple,
    namespace_prefix = 'opencode_question',
    keymaps = {
      left = { 'h', '<Left>' },
      right = { 'l', '<Right>' },
      select_aliases = is_multiple and {} or { '<Tab>' },
      toggle_aliases = is_multiple and { '<Space>' } or {},
    },
  })

  M._dialog:set_group_selection(M._current_question_index)
  M._dialog:setup()
end

---Tear down the active question dialog, if any.
function M._clear_dialog()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
end

function M._clear_inline_input()
  if M._inline_input then
    local handle = M._inline_input
    M._inline_input = nil
    handle.close()
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

  local options_to_display = get_display_options(question_info)
  local progress = ''
  if M._current_question and #M._current_question.questions > 1 then
    progress = string.format(' (%d/%d)', M._current_question_index, #M._current_question.questions)
  end

  local prompt = question_info.question .. progress
  local choices = {}
  for i, option in ipairs(options_to_display) do
    table.insert(choices, option.label)
  end

  local request_id = M._current_question.id
  local question_index = M._current_question_index

  vim.ui.select(choices, {
    prompt = prompt,
    format_item = function(item)
      return item
    end,
  }, function(choice, selected_index)
    if not is_active_question(request_id, question_index) then
      return
    end

    if not choice then
      -- User cancelled
      M._send_reject(request_id)
      M.clear_question()
      return
    end

    if selected_index then
      M._answering = true
      M._answer_with_option(selected_index, request_id, question_index)
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
