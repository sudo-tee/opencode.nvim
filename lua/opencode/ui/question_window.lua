local state = require('opencode.state')
local icons = require('opencode.ui.icons')
local Dialog = require('opencode.ui.dialog')

local M = {}

M._current_question = nil
M._current_question_index = 1
M._collected_answers = {}
M._answering = false
M._dialog = nil

local function render_question()
  require('opencode.ui.renderer').render_question_display()
end

local function clear_question()
  require('opencode.ui.renderer').clear_question_display()
end

---@param question_request OpencodeQuestionRequest
function M.show_question(question_request)
  if not question_request or not question_request.questions or #question_request.questions == 0 then
    return
  end

  M._current_question = question_request
  M._current_question_index = 1
  M._collected_answers = {}
  M._setup_dialog()
  render_question()
end

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

local function find_other_option(options)
  for i, opt in ipairs(options) do
    if vim.startswith(opt.label:lower(), 'other') then
      return i
    end
  end
  return nil
end

local function get_total_options(question_info)
  local has_other = find_other_option(question_info.options) ~= nil
  return has_other and (#question_info.options + 1) or #question_info.options
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

local function add_other_if_missing(options)
  for _, opt in ipairs(options) do
    if opt.label:lower() == 'other' then
      return options
    end
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

  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and M.has_question()
  end

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

  local function on_dismiss()
    if not check_focused() then
      return
    end
    M._send_reject(M._current_question.id)
    M.clear_question()
    render_question()
  end

  local function on_navigate()
    render_question()
  end

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

function M._clear_dialog()
  if M._dialog then
    M._dialog:teardown()
    M._dialog = nil
  end
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
