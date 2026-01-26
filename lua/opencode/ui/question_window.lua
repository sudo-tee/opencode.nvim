local state = require('opencode.state')
local icons = require('opencode.ui.icons')

local M = {}

M._current_question = nil
M._current_question_index = 1
M._collected_answers = {}
M._key_capture_ns = nil
M._hovered_option = 1
M._option_line_map = {}
M._answering = false
M._question_keymaps = {}

local function toggle_input_window(show)
  require('opencode.ui.input_window')[show and '_show' or '_hide']()
end

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
  M._hovered_option = 1
  M._setup_key_capture()
  render_question()
  toggle_input_window(false)
end

function M.clear_question()
  M._clear_key_capture()
  M._current_question = nil
  M._current_question_index = 1
  M._collected_answers = {}
  M._hovered_option = 1
  M._option_line_map = {}
  M._answering = false
  render_question()
  toggle_input_window(true)
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
    M._clear_key_capture()
    M._hovered_option = 1
    M._setup_key_capture()
  end
  render_question()
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
  if not M.has_question() then
    return
  end

  local question_info = M.get_current_question_info()
  if not question_info then
    return
  end

  local formatter = require('opencode.ui.formatter')
  local start_line = output:get_line_count()

  local progress = ''
  if M._current_question and #M._current_question.questions > 1 then
    progress = string.format(' (%d/%d)', M._current_question_index, #M._current_question.questions)
  end

  output:add_line(icons.get('question') .. ' Question' .. progress)
  output:add_extmark(start_line, { line_hl_group = 'OpencodeQuestionTitle' } --[[@as OutputExtmark]])
  output:add_line('')
  output:add_line(question_info.question)
  output:add_line('')

  local options_to_display = add_other_if_missing(question_info.options)
  local num_options = #options_to_display

  M._option_line_map = {}
  for i, option in ipairs(options_to_display) do
    local label = option.label
    if option.description and option.description ~= '' then
      label = label .. ' - ' .. option.description
    end

    local line_idx = output:get_line_count()
    local line_text = M._hovered_option == i and string.format('    %d. %s ', i, label)
      or string.format('    %d. %s', i, label)

    output:add_line(line_text)
    M._option_line_map[i] = line_idx

    if M._hovered_option == i then
      output:add_extmark(line_idx, { line_hl_group = 'OpencodeQuestionOptionHover' } --[[@as OutputExtmark]])
      output:add_extmark(line_idx, {
        start_col = 2,
        virt_text = { { '› ', 'OpencodeQuestionOptionHover' } },
        virt_text_pos = 'overlay',
      } --[[@as OutputExtmark]])
    end
  end

  output:add_line('')

  if M.has_question() and not M._answering then
    local ui = require('opencode.ui.ui')
    if ui.is_opencode_focused() then
      output:add_line('Navigate: `j`/`k` or `↑`/`↓`  Select: `<CR>` or `1-' .. num_options .. '`  Dismiss: `<Esc>`')
    else
      output:add_line('Focus Opencode window to answer question')
    end
  end

  local end_line = output:get_line_count()
  formatter.add_vertical_border(output, start_line + 1, end_line, 'OpencodeQuestionBorder', -2)
  output:add_line('')
end

function M._setup_key_capture()
  if not M.has_question() then
    return
  end

  M._clear_key_capture()

  local question_info = M.get_current_question_info()
  if not question_info or not state.windows or not state.windows.output_buf then
    return
  end

  local buf = state.windows.output_buf
  local total_options = get_total_options(question_info)

  local function check_focused()
    local ui = require('opencode.ui.ui')
    return ui.is_opencode_focused() and M.has_question()
  end

  local function navigate(delta)
    return function()
      if not check_focused() then
        return
      end
      M._hovered_option = M._hovered_option + delta
      if M._hovered_option < 1 then
        M._hovered_option = total_options
      elseif M._hovered_option > total_options then
        M._hovered_option = 1
      end
      render_question()
    end
  end

  local function select_option()
    if not check_focused() then
      return
    end
    M._answering = true
    render_question()
    M._clear_key_capture()
    vim.defer_fn(function()
      M._answer_with_option(M._hovered_option)
      M._answering = false
    end, 100)
  end

  local function dismiss_question()
    if not check_focused() then
      return
    end
    M._send_reject(M._current_question.id)
    M.clear_question()
    render_question()
  end

  M._question_keymaps = {
    vim.keymap.set('n', 'k', navigate(-1), { buffer = buf, silent = true }),
    vim.keymap.set('n', 'j', navigate(1), { buffer = buf, silent = true }),
    vim.keymap.set('n', '<Up>', navigate(-1), { buffer = buf, silent = true }),
    vim.keymap.set('n', '<Down>', navigate(1), { buffer = buf, silent = true }),
    vim.keymap.set('n', '<CR>', select_option, { buffer = buf, silent = true }),
    vim.keymap.set('n', '<Esc>', dismiss_question, { buffer = buf, silent = true }),
  }

  M._key_capture_ns = vim.api.nvim_create_namespace('opencode_question_keys')

  vim.on_key(function(key, typed)
    if not check_focused() or typed == '' then
      return
    end

    if not M.has_question() then
      M._clear_key_capture()
    end

    local num = tonumber(key)
    if num and num >= 1 and num <= 9 and num <= total_options then
      M._answering = true
      M._hovered_option = num
      render_question()
      M._clear_key_capture()
      vim.defer_fn(function()
        M._answer_with_option(num)
        M._answering = false
      end, 100)
    end
  end, M._key_capture_ns)
end

function M._clear_key_capture()
  if M._question_keymaps then
    for _, keymap_id in ipairs(M._question_keymaps) do
      pcall(vim.keymap.del, 'n', keymap_id, { buffer = state.windows.output_buf })
    end
    M._question_keymaps = {}
  end

  if M._key_capture_ns then
    vim.on_key(nil, M._key_capture_ns)
    M._key_capture_ns = nil
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
